## 1.72.1

- Fixed: dragging something toward the red centre line of the grid settled it on a magenta guide just left or right of the line instead of on it. The centre line is no longer an ordinary grid line. Bring a group's or a tracker's middle within half a grid step of the middle of the screen, at most 12, and it goes there, with a guide drawn over the red line to say so. That holds at every grid size, including for wide groups that used to land a few units off centre with no guide at all.
- Lining up with other trackers is more deliberate. It is like with like: an edge with an edge, a middle with a middle, never a middle with an edge, which is what put a group's middle on another group's side. A group's outline can be lined up with from anywhere on the screen, but the trackers inside a group only offer their middles, and only when they are near what you are dragging, so a row of icons is no longer a solid band of magnets. A line that sits within 12 of the centre is left out at every grid size, so no guide ever appears a few units beside the red one. Lining something up in a way that would leave its middle just off the centre puts it on the centre instead.
- The grid never carries something back across a line it could have lined up with, so nothing jumps backwards as you drag forwards.
- A bar can still be lined up top to top or bottom to bottom with a neighbour that is itself centred. Between that and the centre, whichever is nearer wins, so a narrow bar no longer flickers between the two as you drag steadily.
- Fixed: tooltips came up over other trackers while a group was being dragged by its plate.
- Fixed: locking or unlocking from the minimap button left the grid drawn, or turned snapping on with no grid and no edit bar. It now does exactly what Edit layout does.
- Fixed: dragging every tracker of a group at once, marked with shift-click, by one of its icons put the group where that one icon was aimed rather than where the group was, and lined it up with its own old outline.
- Fixed: a group whose drag was cut short, by arranging being turned off mid-drag, went on following the cursor.
- Fixed: a group held by its plate when arranging ended, and hidden because its tracker only shows while its buff is up, never had its drag ended. Tooltips stayed off for the rest of the session, and the stale drag could later drop that tracker into another group. The drag is now let go where the group was when arranging ends, however it ends (Done, the minimap button, the slash command, or closing the window), and it is not treated as a drop.
- Fixed: a spell dragged from the book against a free side of a cluster icon could shift icons already in the cluster. It now goes on the end first and then moves into the cell it was held against, so the others stay where they were.
- A tracker dragged into the open from the book or from the Groups and trackers list now lands where the grid shows it will, at its own size.

## 1.72.0

- New: an alignment grid while arranging. The bar that appears in edit mode has a **Grid** checkbox that lays lines over the whole screen, measured out from its middle so a group can be put dead centre. The cross through the middle, every fourth line, and the rest are each drawn in their own color, so distance can be counted off it.
- **-** and **+** beside it change how far apart the lines are, from 8 to 128.
- **Snap to grid** settles a group or a tracker on the nearest line as you drag it, by whichever of its edges or its middle is closest to one. A group follows the grid as it moves, and a tracker dropped in the open shows where it will land before you let go.
- While the grid is up, trackers also line up with each other: bring an edge or the middle close to another tracker's edge or middle and it lines up exactly, with a guide line drawn across the screen while it does. Lining up with another tracker takes priority over the grid, since it is usually what you are aiming for, and it still works with Snap to grid turned off.
- Hold **Alt** while dragging to place something freely, with no snapping or lining up at all.
- The grid is only there while arranging, and it remembers whether you left it on.
