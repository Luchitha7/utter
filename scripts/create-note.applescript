on run argv
    tell application "Notes"
        activate
        make new note with properties {body:item 1 of argv}
    end tell
end run
