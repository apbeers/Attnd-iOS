# iPhone Duo Manual Test Checklist

**Without the hardware**: Xcode 27.1's Device Hub simulator can open, close and partly fold the Duo (UI only; `simctl` has no
fold command). Launch a Debug build with `-AttndDebugRegions YES` to draw the reserved regions (fold red, camera housings orange)
and the floating controls' frames (dashed blue: plan / search button, composer, banners, Undo toast). The manual **Duo
screenshots** workflow (`.github/workflows/duo-screenshots.yml`, `scripts/ci/duo_audit.sh`) captures Home, Schedule, the Map, a
place's detail and the chat folded, unfolded portrait / landscape and in tabletop with that overlay (artifact `duo-audit`, a
black-capture check and `report.txt`; the chat only where the simulator has Apple Intelligence). Previews: `FoldableLayout.swift`
("Duo outer" / "Duo inner" / "Duo inner landscape", approximate point sizes) and the Live Activity's in `EventLiveActivity.swift`.

Run on an iPhone Duo (or the iPhone Duo simulator) with a joined event that has locations with and without coordinates, a schedule, a flyer and notifications. Repeat with a `festival`-style event (clustering, category chips, `secondary_pane: schedule`).

## Postures

Test each posture **upright and rotated 90° both ways**. Change posture **while each screen is open**, not only between screens.

| Posture | Expected size class | Check |
|---|---|---|
| Closed (outer screen) | compact width | Single-column tabs; Map tab shows the map only |
| Open, tall | compact / regular depending on width | Nothing sits under the horizontal fold; map buttons and card stay at the bottom |
| Open, wide | regular width | Map tab shows map + secondary pane side by side; Locations / Schedule show list + detail |
| Partially folded (L shape) | per active region | Content and overlays stay off the hinge; no frozen layout mid-fold |
| Tent | per facing screen | App fills the facing side; toolbar items readable |
| Laptop | regular width | Bars may move vertical: every toolbar item shows its icon with an accessible title |

## Per screen

- [ ] **Launch**: content extends under the status bar / camera; the QR (leading) and Join (pinned trailing) toolbar items keep icon + title; search field works in every posture.
- [ ] **Map**: chips, the re-centre / my-location buttons, the search button below them (one trailing column) and the selected-location card avoid the fold and camera housings and never overlap; clusters split when zooming in; camera position survives fold/unfold; re-tapping the Map tab re-centres.
- [ ] **Map + secondary pane** (wide): pane matches `secondary_pane`; tapping a location in the pane focuses its pin; switching back to compact keeps the map where it was.
- [ ] **Locations**: list → detail split on wide, push on compact; selection survives fold/unfold; hero image extends under the bars (`backgroundExtensionEffect`); search and chips work.
- [ ] **Schedule**: style follows `schedule_style`; times in the event's time zone; filter menu (icon + title) opens as a menu, not a clipped popover; split view on wide.
- [ ] **Flyer**: doesn't reload on every fold/unfold or rotation.
- [ ] **Updates**: pull to refresh; tapping a push opens this tab.
- [ ] **Search button** (devices without Apple Intelligence, and screenshot mode): the floating glass magnifying glass sits bottom-trailing above the tab bar on every tab, clear of the fold and camera housings; it opens the search sheet with the field focused and the keyboard up; results push details, Back returns to the results.
- [ ] **My plan button** (with Apple Intelligence): the floating glass `sparkles` button and its peek ("Next: … · 7:00 PM · …") sit bottom-trailing on every tab instead of the search button, clear of the fold and camera housings; it opens the plan page.
- [ ] **My plan chat, folded / compact** (Nov 21, 2026 build): one chat (no separate plan page); typing shows nothing until Return; your message appears as a right bubble, then the working line ("Searching…", "Adding Taco Row…") turns into "✓ Added Taco Row" with the answer's components inline; follow-up chips sit above the composer; the composer stays on the keyboard and off the camera housing; history scrolls and survives closing and reopening the page.
- [ ] **My plan chat, unfolded wide (landscape)**: chat column leading, the last shown component large trailing, split exactly on the fold; **unfolded portrait** (taller than wide): the chat alone (`.split.axes(.horizontal)`).
- [ ] **Fold mid-chat**: fold and unfold while the working line runs, with text typed in the composer, and with a proposal card waiting: the transcript, the scroll position (bottom), the composer text, the proposal and the working line are all still there.
- [ ] **Heart**: the outline heart on a place or item saves it at once (Undo toast above the tab bar, clear of the fold and cameras); the filled heart opens Set a Time… / Change Time… / Remind Me / Remove on both displays; fold / unfold with "When?" (Set a Time…) open: it re-presents on the new display (or closes cleanly) and a chosen time is saved once.
- [ ] **Tab bar placement** (decided Nov 21, 2026: the system default, no `defaultTabBarPlacement` modifier): on the outer display and the inner display's side positions the tab bar goes vertical with the event's tabs (icon + title); compare once with `.defaultTabBarPlacement(.sidebar)` in Device Hub and note the result here.
- [ ] **Place / item detail, unfolded (≥ 700 pt)**: two columns — header, walk map and directions (item: header, place, countdown) leading, the rest trailing; folded: one column; the hero image still extends under the bars.
- [ ] **Tabletop** (partly folded, fold across the middle): Home shows header / urgent / countdown / map above the fold and the rest as a list below it; the chat keeps the composer below the fold; nothing sits on the fold.
- [ ] **Home header**: plain text (event name, "Sat Nov 21 · Panther Island, Fort Worth"), no card, no code; the urgent card is one line + body and swipes away sideways with an Undo toast (still in Updates).
- [ ] **Home, unfolded**: header / urgent / countdown / now-next full width, then two columns (Up Next in My Schedule beside the map, …) from 700 pt of container width; folded: one column; the last section scrolls clear of the tab bar and the floating button.
- [ ] **Schedule tab**: the My Schedule section first (ended entries dimmed), organizer-change rows (Keep / Remove / Find Another) readable on the cover display; split view on the inner display.
- [ ] **VoiceOver across the fold**: in the chat and on Home (two columns), the reading order goes leading column top to bottom, then trailing; nothing is skipped at the fold.
- [ ] **Live Activity**: the island is vertical on the outer display's right edge: compact leading turns into a progress ring and trailing into Next's clock time ("3:00") where `isDynamicIslandLimitedInWidth`; never an empty region; the theme's primary / secondary / tertiary (API-023) in light and dark (urgent stays red). Extensions may not run in the Duo simulator runtime: check on hardware.
- [ ] **Options**: the gear item (icon + title, pinned trailing) is on every tab's root screen and opens Options as a sheet; toggles work; leave-event confirmation dialog is presented correctly in each posture.
- [ ] **Banners**: Demo / ended banners stay below the navigation bar in every posture.
- [ ] **Newest-update banner**: the glass card above non-Updates tabs stays readable and tappable in every posture, never under the fold or a camera housing; dismiss works; the Updates tab badge clears once Updates is shown.
- [ ] **Map glance**: the "now playing" strip sits under the chips (both clear of the fold and camera housings, below the status badges); pin badges (live dot / "Next 7:30") stay attached to their pins after fold/unfold; the selected-location card shows distance, arrow and walk without overlapping the map buttons or the search button; the walking route line survives fold/unfold.
- [ ] **Compass arrows**: with the phone held in each posture and rotation, arrows point the right way (iOS 27 `headingBody` follows the active display); they stop updating when the app goes to the background.
- [ ] **Peek**: long-press previews on Locations and Schedule rows present correctly in each posture.
- [ ] **Urgent banner**: the red-tinted glass card (urgent announcement) above non-Updates tabs wraps its text, stays clear of the fold and camera housings, opens Updates at the item and dismisses in every posture.
- [ ] **Onboarding (Tour)**: the cards page horizontally in every posture and rotation, Next / Done stays above the home indicator and off the fold, Skip (icon + title) closes them; permission prompts appear on the active display; reopen from Options → Tour.
- [ ] **Live Activity**: with an item hearted, the activity starts while the app is open (Options → Lock Screen → Start Now otherwise). Check the Lock Screen on the **cover display (folded) and the inner display (unfolded)**, StandBy, and the Dynamic Island compact / minimal / expanded (long press) on both displays and in landscape (iOS 27 narrows the island: an icon instead of the countdown). Now and Next both show (Now "At the event" while My schedule has a gap, "Free until 3:00 · Next: X at Y", "Gates open 10:00 · First: X"), with "↗ 0.4 mi · 8 min walk" to Next (VoiceOver "Northeast, 0.4 miles") from a position ≤ 30 min old; countdown and progress tick; Skip / Map buttons work from the Lock Screen and the expanded island (no Add / heart button); tapping a region opens the item, the map (with the walking route) or Updates on the display in use; an urgent announcement shows first and its alert lights the screen.

## Batch 7: fold continuity and the Duo screens

- [ ] **Map, fold with a pin selected** (pane open, unfolded): fold → the same pin is selected with its card and route, the camera where it was, chips unchanged; unfold → the pane shows the same set highlighted. Instruments: one `MKMapView` init per Map tab.
- [ ] **Linked panes** (`secondary_pane: schedule`): tap a set → the map flies to its stage (card + walking route), the row highlighted; tap another pin → the pane scrolls to that place's next set; heart on either side shows on the other at once.
- [ ] **Time travel** (unfolded Map): drag the scrubber → lit pins / grey pins and the Now playing strip follow, a tick at each set start, the label reads "Sat 7:30 PM", Now resets; VoiceOver adjusts it.
- [ ] **Scroll positions**: Home, Schedule, Places scrolled halfway → fold, unfold, half-fold: the same section / rows stay in view; the chat stays at the bottom.
- [ ] **Undo toast** (unfolded / partly folded): heart something in the leading pane → the toast is centred in that pane; in the trailing pane → there; never across the fold, never over the floating button.
- [ ] **Tabletop Home** with DEMO (happening now): top half Now / Next big with the countdown ticking and the urgent card, nothing on the fold; bottom half the list, with "Propped up at the event?" once; Turn On → the controls (Map, heart, Directions, What's next); Exit returns; the offer never comes back.
- [ ] **Stage vs stage**: Schedule unfolded with nothing selected → two line-ups side by side, clashing sets marked; switch either stage; tap a set → its detail.
- [ ] **Planning board**: My plan unfolded → Your Day + Coming Up; drag a set onto the board → the proposal card in the chat; Apply → the day and route redraw; Undo.
- [ ] **Drag between panes**: drag a schedule row onto the map (shows its stage), onto Home's Up Next (added, Undo toast).
- [ ] **Flyer + map**: Flyer tab unfolded landscape → flyer leading, map trailing; chips for places printed on the flyer; tap → the map flies there; fold → the flyer alone, not reloaded.
- [ ] **Empty glass circle** (outer display, Home): with `-AttndDebugRegions YES`, every glass element of ours has a blue label; report the label (or none) next to the circle.
- [ ] **Vertical Dynamic Island**: compact trailing shows Next's clock in bold rounded digits; urgent shows the red triangle.

## Sheets and popovers

- [ ] QR scanner sheet: presented as a sheet on compact, a form sheet on wide; Cancel (`xmark` + title) is in the cancellation slot.
- [ ] Confirmation dialog (leave event) and the Schedule filter menu anchor correctly after folding with them open.
- [ ] Location-denied alert appears centred and dismisses in every posture.

## QR scanner

- [ ] Camera preview fills the sheet in each posture and rotation.
- [ ] Fold / unfold / rotate **while scanning**: preview resumes within ~½ s, never freezes.
- [ ] Background the app with the scanner open, return: scanning resumes.
- [ ] A code scanned right after a posture change still joins the event once (no double join).

## Regression

- [ ] Closed-phone experience matches the pre-Duo app (no new layout bugs on regular iPhones).
- [ ] App Clip launched from a join link: same screens, all orientations.
