# SADROG — changelog

## 1.6.0
- Export, smaller files: compressed video is now written with constant quality by default (new **Control** in Advanced: Quality / Average rate / Target size), key frames every 5 s instead of every 1 s (they were 50–60 % of the bytes of a tutorial export), explicit Rec.709 colour tags. Measured on 60 s of 4K tutorial material (H.264): about 0.9–2 Mb/s at quality Balanced–High versus 15–19 Mb/s before, with the text still readable at 1:1; HEVC is a further 10–38 % smaller. Camera-type motion costs more (7–24 Mb/s at 4K).
- New preset **Tutorial / screen capture (recommended)** (H.264, quality High, 5 s key frames) and a size estimate shown as a range; **Target size** is an honest one-pass estimate (usually a few percent under), not a guarantee; the encoder has no multi-pass.
- Fixed: the *Compact 720p* preset and the *medium* tier exported 568×320 (system medium preset) while announcing 1280×720; they now write the announced size. Presets saved before keep their id and meaning (mapped to a quality).
- Fixed: a rare "writer stalled on the video input" that could freeze an export for two minutes; the feed loop no longer blocks on one stream.
- Export start, end and failures are now written to the diagnostic log.
- Project format unchanged. Default export now differs from 1.5.0 (smaller, constant quality); choose *Document* or an explicit rate for the old behaviour.
- Tests: rate-control rules, size-target arithmetic, quality honoured by both codecs, key-frame distance and colour tags, repaired medium tier, old presets decoding; export suites repeated 4× with no stall. Measurements: docs/EXPORT_MEASUREMENTS.md.
- Docs: manuals RO/EN/ES and the product page updated in the Advanced export section (rate control, Tutorial preset, size range); the Advanced export screenshot was NOT retaken (screen control was not granted for this lot) and its caption says it predates 1.6.0; README unchanged; install and price text unchanged.

## 1.5.0
- Inspector: exclusive tabs (Video, Sound, Time, Cursor), only those that apply to the selection; double-click on a slider (or its reset button) returns it to the neutral value as one Undo step.
- Timeline: a Volume tool (double-click adds a point, drag for time and level, Delete removes, ⇧ fine, ⌥ without the 0 dB magnet, Esc cancels); fade handles for length and curvature and a crossfade drawn as an X with the real curves and an editable shape; a keyframe band under the selected video clip (click, drag in time, double-click to add, Delete to remove, ⇧ fine, Esc cancels).
- Shortcuts: Settings ▸ Shortcuts lists every command, lets you search, change, remove and reset combinations, warns about conflicts and keeps system combinations fixed; menus and hover explanations show the real combination.
- Key commands on screen (opt-in, off by default): Settings ▸ Recording ▸ Save keyboard commands keeps only ⌘/⌃/⌥ combinations and function keys while recording (the system delivers every key press to the app; each is classified at once and typed text is discarded, never stored; nothing is saved while Secure Input is on); the Cursor tab can show them as keys at the bottom of the picture, in the viewer and in the export. Independent of any other plug-in.
- Recent: Open, Show in Finder, Locate… (missing project) and Remove from Recent; when the file is missing, “Show in Finder” says it only opens the parent folder. A finished recording opens a sheet: Create document and open, or Keep only the recording.
- Fixes found in the final check: a volume point, a keyframe or a curve handle now responds only over the handle itself (it used to answer over the whole row), and the fade handles are no longer covered by the volume line; the back button now says it returns to the start screen (new recording, new document, Recent).
- Project format unchanged (older projects open unchanged; a clip may carry a key-command display flag).
- Tests: gesture and fade/crossfade models, shortcut registry (conflicts, reserved combinations, persistence), key commands (filtering, recorder, rendering in the export, archive); the suite figures are in docs/reviews/1.5.0.txt.
- Docs: manuals RO/EN/ES and the product page regenerated with the screenshots of the main editor, audio, camera overlay, effect and title inspectors retaken from this version in the three languages (synthetic demo project); text covers inspector tabs and sliders, configurable shortcuts, direct volume / fade / crossfade editing, the keyframe band, key commands on screen and Recent. The recording, export, source-details, activation, permissions and new-document screenshots are those of the previous versions (those screens did not change). README unchanged (no feature list); install and price text unchanged.

## 1.4.0
- Speed: any clip (and any picture or sound item) can be retimed — 0.25×, 0.5×, 1×, 2×, 4×, 6× or a value between 0.1× and 16× — with the resulting length shown in the inspector; the following main-track clips move, independent tracks never move arbitrarily and a change that would overlap is refused with the reason. Source, local and timeline clocks are separate; playback, thumbnails, waveform, export, cuts, fades and keys use one mapping. Keep-pitch and "no sound at this speed" options; slow motion repeats frames (no motion interpolation); no reverse and no speed ramps. Old projects open at 1×.
- Volume: automation points in dB on a sound (add, drag on the timeline (Esc cancels a drag in progress), edit in numbers, step between points, reset; "Mute" is explicit silence), fade-in and fade-out with linear / slow-in / slow-out / S-curve shapes and adjustable curvature, and a crossfade between two independent sounds (drawn as an X, equal gain or equal power, duration = real overlap, refused when the source has no material). The mix order is documented and measured in the export; the master volume never enters stems.
- Animation keys: every key has its own interpolation to the next one (default, linear, step, slow-in, slow-out, smooth); move keys in time, step between keys and edit one property without touching the others. Cuts, trims and speed changes keep what you see, including the interpolation of the cut segment.
- Voice: presets (high-pass filter only, clean voice, podcast voice, limiter only) made of Apple's own high-pass filter, dynamics processor and peak limiter through the existing plug-in host — each stage can be bypassed, moved, opened or deleted. The expander is conservative and is not noise removal.
- Project format 18 (older projects open unchanged).
- Tests: retiming maps and durations, A/V sync after several retimed segments, measured automation / fades / crossfade (correlated and unrelated sounds) in the export, keys across cut / trim / speed, voice presets on synthetic signals, copy / duplicate / split / save-reopen / locked tracks.
- Docs: manuals RO/EN/ES and the product page — new sections for clip speed, volume automation / fades / crossfade, voice processing and animation keys (text blocks; no new screenshots were taken); README unchanged (no feature list); install and price text unchanged.

## 1.3.0
- Recording screen: redesigned. Each source (screen, camera, microphone) has its own card with its real settings; “Add source” and a ruby “Start recording” button sit in a footer that always stays visible, with the folder and the countdown beside it. The window keeps everything reachable at its minimum size, in the three languages and in both themes.
- Camera: a Format menu (Automatic or a specific format) with the current mode shown next to it; an on-demand preview that explains each state (waiting, permission needed, camera missing, ready) and never starts the recording; a missing camera is shown once, by its name.
- Microphone and interface: an on-demand input level meter with a dBFS readout and the selected channels; channel choice never changes the audio interface settings.
- Screen: the capture size is shown on the card, with “Resolution details” (logical size, internal macOS rendering, effective capture size) one click away; display, window or region is chosen from the ⋯ menu; the main source is marked.
- Docs: manuals and product page (RO/EN/ES) — recording-screen steps and the source-details section rewritten; the recording, source details, activation, permissions and new-document screenshots were retaken in the three languages; README unchanged; install and price text unchanged.

## 1.2.1
- Timeline: the Blade tool cuts the whole selection — with several items selected, one click on one of them cuts every selected item that crosses that instant (V1, camera, detached sound, titles…), at exactly the same time, as one Undo step; a click on an item outside the selection cuts only that item; a locked track refuses the cut as a whole. The vertical guide turns yellow and shows how many items will be cut.
- Timeline: selected items have a clear yellow outline with a dark edge (it turned brown in the Light theme), visible over thumbnails, waveforms and any track colour; hover and the drop destination (blue) are distinct from the selection.
- Plug-in windows: a second plug-in window no longer opens exactly over the first — it is offset and kept inside the screen.
- Docs: rectangle-selection section of the manuals and the product page (RO/EN/ES) describes the Blade on a selection and the selection outline; the screenshots with a selected item were retaken; README unchanged; install and price text unchanged.

## 1.2.0
- Timeline: mixed selection move — video clips from the main track, camera, titles, highlights and sounds selected together move as one: the clip block is re-inserted at the nearest boundary between clips, the other items shift by the same distance, detached sound travels with its clip, and the timing relationship between them stays identical. While dragging, a dashed outline shows where the block lands; an impossible destination (locked track, overlap, non-adjacent clips, a transition between them) is explained and nothing changes. One Undo step.
- Export: the compressed export can no longer wait forever — each stream is finished as soon as it runs out and a writer that stops advancing is stopped with a clear message instead of leaving the export hanging.
- Docs: the activation screenshot no longer shows the contribution amount (it appears only in the app); the manuals and pages were re-checked page by page.
- Docs: manuals RO/EN/ES and the product page updated (mixed selection move, destination marker, refusals); README unchanged (no feature list); install and price text unchanged.

## 1.1.0
- Timeline: rectangle selection — with the Select tool, drag from free space to select clips, titles, highlights and sounds across tracks (⇧/⌘ add, Esc cancels, a click in free space clears; the timeline scrolls at the edge). Selected items move together keeping distances and sync; “Cut selected items at the playhead” (⇧⌘K) cuts only the selection; locked tracks refuse the whole operation with an explanation; main-track clips are never moved in time together with other items.
- Timeline: a cut clip from the main track can be moved to a video track (V2) keeping its properties and links; titles that overlap now sit on independent rows.
- Circular presenter: “Frame the image in the circle” — drag and scale the whole faded camera frame under a fixed circle, with no gaps, one Undo step, guides never exported.
- Highlights: Lens — the chosen area is shown magnified in a separate area.
- Interface: hover explanations for icon-only buttons, tools, handles and stateful or disabled controls (Romanian, English, Spanish).
- Docs: manuals RO/EN/ES and the product page updated (selection and cut on selection, move to V2 and title rows, circle framing, lens); README unchanged (no feature list); install and price text unchanged.

## 1.0.2
- Editor: after detaching a clip's sound, selecting the separate audio item shows its source sounds again — volume, mute and the audio-effect chain with its plug-in windows — and the item stays editable from its own selection.
- Tracks: a larger, always-visible grab handle for moving a track up or down; dragging a video overlay above the top track, or a separate audio item below the last one, creates a new track there (a dashed "New track" band shows where it will land).
- Tests: the effect chain (order, bypass, plug-in state) is verified through detach, cut, move to another track, track reorder, undo/redo and save/reopen.

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
