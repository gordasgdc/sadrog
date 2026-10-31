# SADROG — changelog

## 1.0.1
- Help ▸ User Manual… (also in the About window): opens the manual PDF in the language chosen in SADROG — Romanian, English or Spanish — independent of the system language.

## 1.0.0 — first public release
- Screen, window, camera and audio recording on macOS 15+ (Apple Silicon), with per-source tracks, optional pointer and foreground-window metadata, and a destination you choose.
- Editor: timeline with tracks, trimming, cross-dissolves, titles, highlights, callouts, animation, per-recording audio with Audio Unit effects, and presets.
- Export: copy without re-encoding, compressed, ProRes master, and a lossless frame sequence + WAV; the destination is protected and a cancelled export leaves no partial file.
- Projects open from older versions (format 16 reads formats up to 15) and are saved safely.
- Languages: Romanian, English, Spanish. Dark, Light and System appearance.
- Access: a 5-day Full trial approved by the owner and started at the first activation, or a permanent activation (conditions available in the app). Without activation you can still open, edit, save and recover projects; a new recording and an export need an active trial or permanent activation.
- Updates: checked from https://gordas.dev/sadrog/update.json.

## 0.6.0 (intermediate build, not published)
- Effects dragged onto a clip or overlay now act on it (one undo step, target highlighted); default export name = project name + date.
- Add a recording from the editor into the open project (bar and menu): it joins the end of the main track, one undo step, cancelling returns to where you were.
- Complete native menus (SADROG, File, Edit, Clip, Timeline, View); the same command works from menu, bar and context menu, and text fields no longer send commands to the timeline.
- Click an item directly in the viewer to select it (front-most visible item, repeated click cycles through covered items); the effect box no longer intercepts clicks.
- Detached sound keeps its source identity; reuniting keeps gain/mute or refuses with the reason.
- Export with explicit settings: copy without re-encoding (refused, never silently lossy, when the project needs processing), processed compressed, ProRes master, and a lossless frame-sequence + WAV mode; size (incl. 4K and custom), frame rate and codec are shown in one summary that matches the result.
- Drag and drop: files from Finder or the library onto the library or the timeline, live preview of position and track, snapping, a new-track zone at the edge of V2/A2, explicit refusals (wrong kind, locked track, overlap) before you drop; one undo step.
- Inspector for local highlights: compact target selector; no permanent explanatory paragraphs.

## 0.5.0 (intermediate build, not published)
- Sound can be detached from a clip into its own audio item (menu Clip, right-click, inspector): same position, same source offset, fades carried over, no doubled sound; it can be moved, cut, deleted or reattached. Selecting only the picture or only the detached sound is separate from detaching.
- Tracks: video and audio items move between tracks by dragging (the target track shows whether the item fits before you drop), tracks can be reordered, named, added and removed when empty; stacking order of video tracks follows the track order, with the top track in front.
- Effects belong to the chosen clip: the button, drawing and inspector use the same target; an effect starts where you asked and several effects can run together on different clips; the timeline shows which clip each effect acts on.
- Project format 15 (older projects open unchanged).

## 0.4.2 (intermediate build, not published)
- Interface: inspector panel titles and the frame-rate label follow the language; the start sidebar fits longer labels.

## 0.4.1 (intermediate build, not published)
- Interface: labels that were not translated now follow the language; long labels in the inspector no longer get cut; the inspector keeps a width where all its tabs fit; appearance choices in Settings update when the language changes.

## 0.4.0 (intermediate build, not published)
- Animation follows editing: cutting, trimming or freezing an animated clip, overlay or title keeps exactly what it showed before and after the cut.
- Cross-dissolve between clips (picture and sound), with explicit length limits.
- Pointer movement: optional recording of the pointer position and clicks (off by default, never keys), highlight and click rings, zoom that follows the pointer.
- Titles: underline, outline, entrance and exit effects, several lines, styles.
- Rectangular frame-only annotation; several keyframes, easing and fades in the inspector.
- Export: one plan for size and format, verified output dimensions and In/Out range.
- Project archive: self-contained copy with relative paths; refuses when media is missing.
- Settings: appearance (system, dark, light), pointer recording, language, countdown, destination.
- Interface: toolbar, ruler and track headers reorganised; dates follow the app language.
