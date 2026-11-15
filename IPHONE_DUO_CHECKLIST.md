# iPhone Duo Manual Test Checklist

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
- [ ] **Search button**: the floating glass magnifying glass sits bottom-trailing above the tab bar on every tab, clear of the fold and camera housings; it opens the search sheet with the field focused and the keyboard up; results push details, Back returns to the results.
- [ ] **Options**: the gear item (icon + title, pinned trailing) is on every tab's root screen and opens Options as a sheet; toggles work; leave-event confirmation dialog is presented correctly in each posture.
- [ ] **Banners**: Demo / ended banners stay below the navigation bar in every posture.
- [ ] **Newest-update banner**: the glass card above non-Updates tabs stays readable and tappable in every posture, never under the fold or a camera housing; dismiss works; the Updates tab badge clears once Updates is shown.
- [ ] **Map glance**: the "now playing" strip sits under the chips (both clear of the fold and camera housings, below the status badges); pin badges (live dot / "Next 7:30") stay attached to their pins after fold/unfold; the selected-location card shows distance, arrow and walk without overlapping the map buttons or the search button; the walking route line survives fold/unfold.
- [ ] **Compass arrows**: with the phone held in each posture and rotation, arrows point the right way (iOS 27 `headingBody` follows the active display); they stop updating when the app goes to the background.
- [ ] **Peek**: long-press previews on Locations and Schedule rows present correctly in each posture.
- [ ] **Urgent banner**: the red-tinted glass card (urgent announcement) above non-Updates tabs wraps its text, stays clear of the fold and camera housings, opens Updates at the item and dismisses in every posture.
- [ ] **Onboarding (Tour)**: the cards page horizontally in every posture and rotation, Next / Done stays above the home indicator and off the fold, Skip (icon + title) closes them; permission prompts appear on the active display; reopen from Options → Tour.
- [ ] **Live Activity**: with an item hearted, the activity starts while the app is open (Options → Lock Screen → Start Now otherwise). Check the Lock Screen on the **cover display (folded) and the inner display (unfolded)**, StandBy, and the Dynamic Island compact / minimal / expanded (long press) on both displays and in landscape (iOS 27 narrows the island: an icon instead of the countdown). Countdown and progress tick; Heart / Skip / Map buttons work from the Lock Screen and the expanded island; tapping a region opens the item, the map (with the walking route) or Updates on the display in use; an urgent announcement shows first and its alert lights the screen.

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
