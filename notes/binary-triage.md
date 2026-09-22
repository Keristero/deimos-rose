# DeimosRising.exe — binary triage

## Identity

| | |
|---|---|
| File | `game/DeimosRising.exe` |
| SHA-256 | `01a9eb04895dbae9b33f586e85ff851de5d100270c493d1c2707745f248ca24f` |
| Size | 1,501,616 bytes |
| Format | PE32, i386, GUI subsystem |
| Link timestamp | 2003-02-24 10:23:57 UTC |
| Image base | `0x400000` |
| Entry point | RVA `0x6dbb0` |
| Packed? | No — normal section layout, intact `.reloc` and `.idata` |

## Toolchain: Metrowerks CodeWarrior (not MSVC)

Three independent signals:

1. A `.exc` section — CodeWarrior's exception-table section. MSVC does not emit one.
2. "Linker version" 3.0, and 2.50 for `Register Deimos Rising.exe`. MSVC 6 reports 6.0.
3. The linked object list names the Metrowerks Standard Library (MSL):
   `ansifp_x86.obj`, `ExceptionX86.obj`, `critical_regions.win32.obj`,
   `startup.win32.obj`, `ClMWerksIntel.obj`, `LongLongx86.obj`.

C++ names use the MSVC-compatible `?name@@YAX...` mangling, so MSVC demanglers
work on them.

This matters for a matching decomp: the target compiler is CodeWarrior for
x86, not any MSVC release. Codegen idioms, struct layout and the exception
model all follow Metrowerks, not Microsoft.

## Mac heritage: the game runs on QuickTime Media Layer

`DeimosRising.exe` statically links QTML — Apple's QuickTime Media Layer, which
implements Mac Toolbox APIs on Win32. Object paths in the debug info still
carry Apple's build tree:

```
\qtml\buildresults\NoSym\obj\qtmlClientPublic\Toolbox\QuickdrawShim.obj
\qtml\buildresults\NoSym\obj\qtmlClientPublic\Toolbox\QDOffScreenShim.obj
\qtml\buildresults\NoSym\obj\qtmlclientpublic\MoviesWin32Glue.obj
\qtml\buildresults\NoSym\obj\qtmlClientPublic\ComponentGlue\ImageCompressionShim.obj
```

Mac Toolbox types survive in the mangled signatures: `CGrafPort`, `BitMap`,
`ColorTable`. This is a Mac-first title ported to Windows through QTML rather
than rewritten — which is why the Read Me requires QuickTime 5.0+ to run.

## The find: 271 KB of CodeView symbols are shipped in the binary

The entire PE overlay (file offset `0x12c600` to EOF, 271,280 bytes) is a
CodeView `NB11` debug blob referenced by `IMAGE_DIRECTORY_ENTRY_DEBUG`. The
release build was never stripped.

It yields **2,692 public symbols** (1,942 in `.text`), covering 100% of the
`0xbd756`-byte text section, plus the full 685-entry translation-unit list in
link order.

One catch, and the reason stock tooling reports nothing: CodeWarrior emits the
CV5-era "ST" symbol records — `S_PUB32_ST = 0x1009` — not the CodeView 4
values (`S_PUB32 = 0x0203`) that a naive parser looks for. The record layout is
`typind(4), off(4), seg(2), pascal-string name`. `tools/cv_parse.py` handles
this.

The CodeView segment map matches the PE section table exactly (segment N == PE
section N-1), which independently validates the RVA mapping:

```
 seg  section   rva         vsize     cv_size
  1   .text     0x00001000  0x0bd756  0x0bd756
  4   .data     0x000c6000  0x056554  0x056554
```

Not present: `sstSrcModule` subsections. There are no line numbers and no
source file paths for the game's own code — the linker kept globals and
publics only. Per-module `sstAlignSym` records exist for 21 DLL import stubs
and nothing else.

## Code layout

`.text` symbols by origin:

| Origin | Symbols | Bytes |
|---|---:|---:|
| Game logic (`G_*`) | 361 | 228,576 |
| Utility/abstraction layer (`U_*`) | 305 | 82,976 |
| libpng (`png_*`) | 127 | 49,068 |
| libjpeg (`jpeg_*`, `jinit_*`) | 45 | 44,504 |
| zlib (`inflate*`, `zlib_*`) | 21 | 9,270 |
| unzip (`Unzip_*`) | 5 | 3,440 |
| MSL, QTML, Ambrosia toolkits, thunks | 1,078 | 358,188 |

Roughly 311 KB of the 775 KB text section is the game's own `G_`/`U_` code;
much of the rest is vendored third-party and runtime code that a decomp can
identify rather than reconstruct.

### Source module structure

The object list recovers the original translation units:

- **`U_*`** — portable utility layer: `U_Error`, `U_File`, `U_FileFormatting`,
  `U_Image`, `U_LinkedList`, `U_Manager`, `U_Math`, `U_Pak`, `U_PixelScale`,
  `U_Prefs`, `U_Sprite`, `U_SpriteBlit`, `U_SpritePlate`, `U_String`,
  `U_Token`, `U_Utils`
- **`G_*`** — game layer: `G_Background`, `G_Briefing`, `G_Button`,
  `G_Console`, `G_Credits`, `G_Debris`, `G_Entity`, `G_EntityGroup`, `G_Film`,
  `G_Game`, `G_GameInterface`, `G_GameObject`, `G_Input`, `G_Interface`,
  `G_Level`, `G_LevelSelection`, `G_Message`, `G_MotionBlur`, `G_Notice`,
  `G_Particle`, `G_Player`, `G_PlayerDefinitions`, `G_Resource`, `G_ScoreBar`,
  `G_Scores`, `G_Text`, `G_UnitDefinitions`, `G_WeaponDefinitions`,
  `G_WeaponHandler`
- **`W_*`** — Win32 backends: `W_Window`, `W_Button`, `W_Configuration`,
  `W_ControlsConfigure`, `W_Display`, `W_Error`, `W_Image`, `W_Memory`,
  `W_Music`, `W_Pixel16`, `W_PixelBuffer`, `W_Profile`, `W_Registration`,
  `W_Sound`, `W_Application`
- Plus `WinMain`, `Win_Utilities`, `Win_Sound_Spool`, `unzip`, `dr`

Note the `W_*` modules export no `W_`-prefixed symbols. They implement the
platform half of the `U_*` API for Windows — e.g. `W_Application.obj` provides
the 24 `U_App_*` entry points (`U_App_Init`, `U_App_ConstructPath`,
`U_App_Event_GetNext`, ...). A Mac build would swap these modules out. That
split is a useful decomp boundary: `U_*` and `G_*` are portable, `W_*` is not.

### Ambrosia shared toolkits

Prefixes that belong to Ambrosia's cross-title libraries, not to Deimos Rising:

| Prefix | Area | Related objects |
|---|---|---|
| `DT_` | Display Toolkit — buffers, alpha, dirty rects | |
| `FT_` | File Toolkit — buffered I/O | |
| `IT_` | Interface Toolkit — dialogs, buttons | `rt3_dialog.obj` |
| `ST_` | Sound Toolkit — AIFF/WAVE, sound pump | `st_common.obj` |
| `PT_` | Parse tree / tokenizer | |
| `SSP_` | Sound spool, music fading | `Win_Sound_Spool.obj` |

`reg_tool_3.obj` / `rt3_common.obj` are Ambrosia's Registration Tool 3, the
shareware licensing component — also the bulk of `Register Deimos Rising.exe`.

## Recovered types

75 type names appear in mangled parameter signatures (43 structs, 25 enums,
7 classes) — see `symbols/types.txt`. Highlights: classes `G_Entity`,
`G_Player`, `G_Film`; structs `G_UnitDef`, `G_WepDef`, `G_PlayerDef`,
`G_Level`, `G_Game_Settings`, `G_Game_Results`; enums `G_Game_PlayerNum`
(referenced by 18 symbols), `G_Res_Type`, `G_WepDef_Type`.

These are names and kinds only. The CodeView type records (`sstGlobalTypes`)
are present but unparsed, so field layouts still have to come from the
disassembly.

## Data formats

`Data/Paks/*.pak` are ZIP archives using stored (uncompressed, method 0)
entries, with entry paths keyed by FourCC directory (`im16/`, `soun/`, ...):

```
00000000: 504b 0304 0a00 0000 0000 4758 ac28 ...  PK........GX.(
00000020: 3136 2f05 270e 005a 5049 5400 0000 ...  16/.'..ZPIT....
```

This is consistent with the `unzip.obj` / `U_Pak` modules and with the
`Unzip_*` and zlib `inflate*` symbols in `.text`.

The loose resource tree under `" Data/Local/"` uses FourCC directory names:
`coli film flli idli im08 im16 leve plde pref reli soun stli tefo unde wede`.

**The leading space in `" Data"` is real.** The binary's own path literals are
`" Data"`, `" Data\Local"` and `" Data\Paks"` — it is not an extraction
artifact, and the directory must keep that name for the game to find its data.

## Validating the recovered map

`tools/validate_symbols.py` checks each `.text` symbol address against the byte
that precedes it. A real function start follows either inter-function padding
or the `ret`/`jmp` ending the previous function:

```
symbols checked: 1941
  nop pad             1209   62.3%
  ret                  713   36.7%
  zero pad              17    0.9%
  unexpected 0xff        1    0.1%
  unexpected 0xf8        1    0.1%
boundary agreement: 99.9%
```

Two exceptions out of 1,941. The RVA mapping is sound.

Prologue shapes are a weaker signal and are informational only: 38% open with
`push ebx` and 35% with `push ebp`, but 24% start straight into argument loads
(`mov ecx,[esp+n]`). CodeWarrior's optimiser drops the frame pointer freely, so
an absent standard prologue does not indicate a bad symbol.

## Correction: there are no type layouts

An earlier draft of this note suggested decoding `sstGlobalTypes` to recover
struct field layouts. That was wrong. The subsection exists but is **8 bytes
long and empty**:

```
sstGlobalTypes: lfo=0x3f64c size=8
```

Subsection sizes overall:

| Subsection | Bytes |
|---|---:|
| `sstGlobalPub` | 162,080 |
| `sstModule` | 94,557 |
| `sstFileIndex` | 2,744 |
| `sstAlignSym` | 1,300 |
| `sstLibraries` | 340 |
| `sstGlobalTypes` | **8 (empty)** |

The 75 type names in `symbols/types.txt` come from mangled parameter
signatures, not from type records. Every struct field offset must be recovered
from the disassembly.

## Linked libraries

`sstLibraries` lists all 25 libraries fed to the linker:

```
winmm  COMctl32  COMdlg32  d3dim  d3dx  ddraw  dinput  gdi32  kernel32
shell32  user32  advapi32  qtmlClient  glut32  opengl32  version  uuid
File_Tool.x86  Interface_Tool.x86  Draw_Tool.x86  sound_tool.x86
Reg_Tool_3.x86  Platform.x86  MSL_All_x86  BurgerW95
```

This names the Ambrosia toolkits directly — `Draw_Tool` (`DT_`),
`File_Tool` (`FT_`), `Interface_Tool` (`IT_`), `sound_tool` (`ST_`),
`Reg_Tool_3` (`RT_`/`rt3`).

**`BurgerW95.Lib` is Burgerlib**, Rebecca Heineman's cross-platform game
library. It accounts for the `Gr*`/`Pl*`/`Sn*`/`Fm*`/`In*`/`OC*`/`Db*`/`Cl*`
manager symbols (`GrGraphicsManager`, `PlPaletteManager`, `SnSoundManager`,
`FmFileManager`, `InKeyboardWin95`, `OCOSCursorManager`, `DbDebugManager`)
and the handle-based allocator (`AllocAHandle2`, `DeallocAHandle`,
`CompactHandles`). An earlier pass in this document misattributed those to
QTML. Burgerlib is now open source, so this code can be matched against
upstream rather than reconstructed.

`d3dim`, `d3dx`, `ddraw`, `dinput`, `glut32` and `opengl32` are linked but
**import zero functions** — Burgerlib's Win95 backend references them and
loads them dynamically. The shipped render path does not use Direct3D or
OpenGL.

## Runtime surface actually used

The Win32 import table is small and maps cleanly onto portable equivalents:

| Area | Win32 used | Portable equivalent |
|---|---|---|
| Video | `CreateDIBSection`, `BitBlt`, `CreateCompatibleDC` (GDI32, 67 fns) | SDL streaming texture / framebuffer |
| Audio | `waveOutOpen/Write/PrepareHeader` (WINMM) | SDL audio, ALSA, PulseAudio |
| Input | `joyGetPosEx`, `joyGetDevCapsA`, USER32 key messages | SDL joystick + keyboard |
| Timing | `timeSetEvent`, `timeGetTime` | `clock_gettime` / SDL timers |

The game renders in software — `U_SpriteBlit`, `W_Pixel16`, `W_PixelBuffer` —
into a 16-bit DIB that is blitted to the window. There is no GPU dependency to
reproduce.

## The manager architecture

`game/DeimosRisingWin32.log` is a developer log shipped in the 2003 build. Its
shutdown sequence enumerates the engine's managers in teardown order:

```
Background, Preferences, Input, Resource, Math, Sound, Music, Pak, Sprite,
Blitter, Level, Unit Definition, Weapon Definition, Player Definition,
Score Bar, Debris, Particle, Motion Blur, Message, Text, Display, Memory,
Manager God
```

These correspond one-to-one with the `G_*`/`U_*` translation units and with
`U_Manager` ("Manager God" being the registry itself). It is a free
architectural map of the engine, straight from the original developers.
