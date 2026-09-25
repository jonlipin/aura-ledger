## 1.71.0

- Bars drain smoothly. Everything a bar shows was being redrawn on the same tenth-of-a-second tick that re-reads cooldowns and works out which trackers belong on screen, so a draining bar moved in ten steps a second. The two jobs are separated now: deciding what should be shown stays on its tenth of a second, and the drawing itself, the fill, the spark and the time, happens every frame.
- The drawing is a handful of calls on the widgets already on screen, and the time text is only written when the wording actually changes, so a smooth bar costs very little.
