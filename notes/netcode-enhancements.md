### Level select
- The host should be able to choose a starting level from the unlocked level list, locked levels will be greyed out and the host will be unable to ready, readying locks in any options that the client has made

### Diagnostics
- With a launch argument, an optional diagnostics display will appear in the bottom right corner, this will display rolling average statistics of:
    - ping of highest ping client [only in multiplayer]
    - rollbacks per second [only in multiplayer]
    - updates per second (excluding rollbacks)
    - frames per second ()

### Synchronise pausing

#### Slow update loop while ahead
- If a client detects that it is running ahead of the other client/s it should increase the duration of its updates to compensate for the other client falling behind, the other client could be falling behind due to network latency however - if the measured network latency is high, the only solution is to increase the buffer size.
- Overwatch developers explained in detail an approach to bring clients back in sync when the updates are drifiting out of sync, its hard to measure who is behind. in ideal circumstances all clients will be simulating the exact same tic at the exact same time.


### Pause on disconnect
- At the very least, if any other client disconnects, the current client should pause automatically to allow the other client to rejoin via the lobby.
- When this happens with 2 clients, both clients will switch into a host mode which accepts a connection from a client attempting to connect by IP address.
- If in the future we supported more than 2 clients in a session, only clients that no longer have any hosts in their session will switch to host mode.
- After switching to host mode, a notice will appear saying "Disconnected, waiting for connections ESC to exit or F5 to continue alone"

### Reconnect
- When a client reconnects, the host needs to send the current game state to the connecting client so that they can resynchronise and continue.

# Netflow enhancements (continued)
- When transitioning between levels, desyncs are occuring, we need to ensure that transitions occur on the same tic for both cients by queing them as an event or something like that