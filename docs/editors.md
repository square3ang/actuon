# Editor preview

Set `actuon` as the player in your editor with these arguments:

| Editor | Setting | Arguments |
| --- | --- | --- |
| BMSE | Options, viewer settings | `-P -N<measure> <filename>` for play, `-S` for stop |
| iBMSC | Options, player arguments | `-P -N<measure> "<filename>"`, stop `-S` |
| uBMSC | same as iBMSC | same |
| BmsONE | Preview settings | `-P -N<measure> "<filename>"` |

The names of the placeholders differ by editor: use the ones it offers for the current measure and file.
These setups have not been tried with the real editors, which are Windows programs; the protocol was exercised from a shell.

A preview plays in autoplay from the start of that measure, and restarts when the file is saved. A second launch does not
open a new window: it hands the command to the running player through `command.json` in the data folder. A player is taken to
be running if its `instance` file there was touched in the last 3 seconds.
