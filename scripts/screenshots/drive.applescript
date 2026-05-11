-- scripts/screenshots/drive.applescript
--
-- Drives the running Photo Export instance through marketing surfaces and
-- captures each one. Invoked by capture.sh after the app has launched with
-- --screenshot-mode. Argument: absolute output directory for the PNGs.
--
-- Captures use `screencapture -R x,y,w,h` against the AppleScript-reported
-- window frame. AppleScript's window `position` and `size` are in screen
-- coordinates (Y=0 at top), matching `screencapture -R`. No CGWindowID
-- lookup needed → no Python / PyObjC dependency.
--
-- Adding a new surface:
--   1. Add a `navigateToX()` handler that drives the UI (keyboard shortcuts
--      preferred over click-by-name — stabler across SwiftUI rebuilds).
--   2. Call `captureWindow(outputDir, "NN-name")` between navigation steps.
--   3. Keep NN monotonically increasing so the marketing upload order stays
--      stable.

on run argv
	if (count of argv) < 1 then
		error "Usage: osascript drive.applescript <output-dir>"
	end if
	set outputDir to item 1 of argv

	tell application "Photo Export" to activate
	delay 0.8

	-- Default landing is Timeline. Capture it first before any navigation,
	-- so the most-likely hero shot lands without UI-scripting variability.
	captureWindow(outputDir, "01-timeline")

	-- Additional surfaces are deliberately deferred. Each needs a navigation
	-- handler whose affordances have been validated against the current
	-- build. Adding more is purely additive — capture.sh picks up every PNG
	-- in $outputDir.
	--
	-- navigateToCollections()
	-- captureWindow(outputDir, "02-collections-favorites")
	--
	-- navigateToFolderGrid()
	-- captureWindow(outputDir, "03-collections-folder-grid")
	--
	-- openAutoExportSettings()
	-- captureWindow(outputDir, "04-auto-export-settings")
end run

-- Captures the front Photo Export window to `<outputDir>/<name>.png`.
on captureWindow(outputDir, name)
	tell application "System Events"
		tell process "Photo Export"
			set winPos to position of window 1
			set winSize to size of window 1
		end tell
	end tell
	set x to item 1 of winPos
	set y to item 2 of winPos
	set w to item 1 of winSize
	set h to item 2 of winSize
	set outPath to outputDir & "/" & name & ".png"
	set rectArg to (x as text) & "," & (y as text) & "," & ¬
		(w as text) & "," & (h as text)
	do shell script "/usr/sbin/screencapture -t png -R " & rectArg & ¬
		" " & quoted form of outPath
	log "Captured " & outPath & " (" & (w as text) & "x" & (h as text) & ")"
end captureWindow
