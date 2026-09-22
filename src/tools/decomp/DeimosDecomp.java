// Headless Ghidra post-script: apply the CodeView symbol map recovered from
// DeimosRising.exe, then decompile and export one C file per function.
//
// Runs after auto-analysis so that function bodies already exist; addresses the
// analyser missed get a function created explicitly.
//
// Args: <functions.csv> <output-dir>
//
// The CSV is the output of ../../tools/cv_parse.py:
//     kind,section,rva,va,size,base,name
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileOptions;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.SourceType;

import java.io.BufferedReader;
import java.io.FileReader;
import java.io.PrintWriter;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

public class DeimosDecomp extends GhidraScript {

	private static class Sym {
		long va;
		int size;
		String base;
		String mangled;
	}

	@Override
	public void run() throws Exception {
		String[] args = getScriptArgs();
		if (args.length < 2) {
			println("DeimosDecomp: need <functions.csv> <output-dir>");
			return;
		}
		Path csv = Paths.get(args[0]);
		Path outRoot = Paths.get(args[1]);
		Files.createDirectories(outRoot);

		List<Sym> syms = readCsv(csv);
		println("DeimosDecomp: " + syms.size() + " .text symbols from " + csv);

		int renamed = 0, created = 0, kept = 0;
		for (Sym s : syms) {
			Address addr = toAddr(s.va);
			Function f = getFunctionAt(addr);
			if (f == null) {
				try {
					f = createFunction(addr, s.base);
					if (f != null) {
						created++;
					}
				} catch (Exception e) {
					// Address may sit inside another function's body; skip.
				}
			} else if (isDefaultName(f.getName())) {
				// Only override Ghidra's own naming where it has nothing: its
				// MSVC demangler is authoritative for the mangled symbols, and
				// it already owns the class namespace. Passing the qualified
				// name here yields "G_Film::G_Film__GetRandomSeed".
				f.setName(unqualified(s.base), SourceType.IMPORTED);
				renamed++;
			} else {
				kept++;
			}
		}
		println("DeimosDecomp: renamed " + renamed + ", kept Ghidra's name for "
				+ kept + ", created " + created);

		DecompInterface di = new DecompInterface();
		di.setOptions(new DecompileOptions());
		if (!di.openProgram(currentProgram)) {
			println("DeimosDecomp: decompiler failed to open program");
			return;
		}

		int ok = 0, failed = 0;
		Set<String> used = new HashSet<>();
		Set<Long> named = new HashSet<>();
		PrintWriter index = new PrintWriter(outRoot.resolve("index.tsv").toFile());
		index.println("module\trva\tsize\tname\tfile\tstatus");

		for (Sym s : syms) {
			if (monitor.isCancelled()) {
				break;
			}
			named.add(s.va);
			Function f = getFunctionAt(toAddr(s.va));
			String module = moduleOf(s.base, s.mangled);
			String stem = sanitize(s.base) + "_" + String.format("%06x", s.va - 0x400000);
			if (f == null) {
				index.println(module + "\t" + hex(s.va) + "\t" + s.size + "\t" + s.base
						+ "\t\tno-function");
				failed++;
				continue;
			}
			if (export(di, f, outRoot, index, used, module, stem, s.base, s.mangled, s.size)) {
				ok++;
			} else {
				failed++;
			}
		}

		// Second pass: functions the symbol map does not name. The CodeView
		// blob lists public symbols only, so file-static functions -- a lot of
		// G_EG and G_Entity behaviour -- appear to be part of the preceding
		// public function (G_EG_CheckIntegrity "is" 15,568 bytes). Ghidra's
		// analysis finds their real boundaries; export them under Ghidra's
		// FUN_ name, filed with the module of the preceding named symbol.
		List<Sym> sorted = new ArrayList<>(syms);
		sorted.sort((x, y) -> Long.compare(x.va, y.va));
		int unnamed = 0;
		for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
			if (monitor.isCancelled()) {
				break;
			}
			long va = f.getEntryPoint().getOffset();
			if (named.contains(va) || f.isThunk() || f.isExternal()) {
				continue;
			}
			var block = currentProgram.getMemory().getBlock(f.getEntryPoint());
			if (block == null || !block.getName().equals(".text")) {
				continue;
			}
			Sym prev = null;
			for (Sym s : sorted) {
				if (s.va > va) {
					break;
				}
				prev = s;
			}
			String module = prev == null ? "_other" : moduleOf(prev.base, prev.mangled);
			String name = f.getName();
			String stem = sanitize(name);
			int size = (int) f.getBody().getNumAddresses();
			String note = prev == null ? "" : "after " + prev.base;
			if (export(di, f, outRoot, index, used, module, stem, name, note, size)) {
				unnamed++;
			} else {
				failed++;
			}
		}
		println("DeimosDecomp: exported " + unnamed + " functions the symbol map does not name");
		ok += unnamed;
		index.close();
		di.dispose();
		println("DeimosDecomp: exported " + ok + ", failed " + failed);
	}

	// Decompiles one function to <module>/<stem>.c and records it in the index.
	private boolean export(DecompInterface di, Function f, Path outRoot, PrintWriter index,
			Set<String> used, String module, String stem, String name, String mangled,
			int size) throws Exception {
		long va = f.getEntryPoint().getOffset();
		DecompileResults res = di.decompileFunction(f, 60, monitor);
		if (res == null || !res.decompileCompleted() || res.getDecompiledFunction() == null) {
			index.println(module + "\t" + hex(va) + "\t" + size + "\t" + name
					+ "\t\tdecompile-failed");
			return false;
		}
		String rel = module + "/" + stem + ".c";
		if (!used.add(rel)) {
			rel = module + "/" + stem + "_dup.c";
		}
		Path out = outRoot.resolve(rel);
		Files.createDirectories(out.getParent());
		try (PrintWriter w = new PrintWriter(out.toFile())) {
			w.println("// " + name);
			w.println("// mangled: " + mangled);
			w.println("// va " + hex(va) + "  rva " + hex(va - 0x400000) + "  size " + size
					+ " bytes");
			w.println("// module: " + module);
			w.println("//");
			w.println("// Generated by Ghidra from DeimosRising.exe. Reference material:");
			w.println("// read it to understand behaviour, do not transliterate it.");
			w.println();
			w.print(res.getDecompiledFunction().getC());
		}
		index.println(module + "\t" + hex(va) + "\t" + size + "\t" + name + "\t" + rel
				+ "\tok");
		return true;
	}

	private static boolean isDefaultName(String n) {
		return n.startsWith("FUN_") || n.startsWith("SUB_")
				|| n.startsWith("thunk_FUN_") || n.startsWith("UndefinedFunction_");
	}

	private static String unqualified(String base) {
		int cc = base.lastIndexOf("::");
		return cc > 0 ? base.substring(cc + 2) : base;
	}

	private static String hex(long v) {
		return String.format("0x%08x", v);
	}

	// Group by translation unit the way the symbol prefixes imply:
	//   U_File::Open        -> U_File
	//   G_Player_Process    -> G_Player
	//   G_EG_BuildDrawList  -> G_EG
	//   png_read_info       -> _thirdparty
	private static String moduleOf(String base, String mangled) {
		// Metrowerks Standard Library template instantiations.
		if (mangled.contains("std@@") || mangled.contains("Metrowerks@@")
				|| base.startsWith("msl_")) {
			return "_msl";
		}
		int cc = base.indexOf("::");
		if (cc > 0) {
			return sanitize(base.substring(0, cc));
		}
		if (base.startsWith("G_") || base.startsWith("U_") || base.startsWith("W_")) {
			int first = base.indexOf('_');
			int second = base.indexOf('_', first + 1);
			if (second > 0) {
				return sanitize(base.substring(0, second));
			}
			return sanitize(base);
		}
		for (String p : new String[] { "png_", "jpeg_", "jinit_", "inflate", "zlib_",
				"Unzip_", "crc32", "adler", "deflate" }) {
			if (base.startsWith(p)) {
				return "_thirdparty";
			}
		}
		for (String p : new String[] { "DT_", "FT_", "IT_", "ST_", "PT_", "SSP_", "RT_" }) {
			if (base.startsWith(p)) {
				return "_ambrosia_" + p.substring(0, p.length() - 1);
			}
		}
		// Burgerlib (BurgerW95.Lib): manager classes and the handle allocator.
		for (String p : new String[] { "Gr", "Pl", "Sn", "Fm", "In", "OC", "Db", "Cl",
				"W9", "Alloc", "Dealloc", "NewHand", "DisposeHand", "CompactHandles",
				"MMMemory", "Atomic", "Critical", "Draw", "ADPCM", "BMP_", "Digital",
				"Burger" }) {
			if (base.startsWith(p)) {
				return "_burgerlib";
			}
		}
		return "_other";
	}

	private static String sanitize(String s) {
		StringBuilder b = new StringBuilder();
		for (char c : s.toCharArray()) {
			b.append(Character.isLetterOrDigit(c) || c == '_' || c == '.' ? c : '_');
		}
		String r = b.toString();
		return r.length() > 120 ? r.substring(0, 120) : r;
	}

	private List<Sym> readCsv(Path csv) throws Exception {
		List<Sym> out = new ArrayList<>();
		try (BufferedReader r = new BufferedReader(new FileReader(csv.toFile()))) {
			String line = r.readLine(); // header
			while ((line = r.readLine()) != null) {
				List<String> f = splitCsv(line);
				if (f.size() < 7 || !f.get(1).equals(".text")) {
					continue;
				}
				Sym s = new Sym();
				s.va = Long.parseLong(f.get(3).replace("0x", ""), 16);
				s.size = Integer.parseInt(f.get(4));
				s.base = f.get(5);
				s.mangled = f.get(6);
				out.add(s);
			}
		}
		return out;
	}

	private static List<String> splitCsv(String line) {
		List<String> out = new ArrayList<>();
		StringBuilder cur = new StringBuilder();
		boolean q = false;
		for (int i = 0; i < line.length(); i++) {
			char c = line.charAt(i);
			if (c == '"') {
				q = !q;
			} else if (c == ',' && !q) {
				out.add(cur.toString());
				cur.setLength(0);
			} else {
				cur.append(c);
			}
		}
		out.add(cur.toString());
		return out;
	}
}
