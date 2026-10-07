/// AppleScript handlers Minutes runs in-process through NSAppleScript. Parameters
/// arrive as Apple event descriptors, so note text is never spliced into source.
enum NotesScriptSource {
    static let text = #"""
-- Handlers Minutes calls in-process (NSAppleScript). Parameters arrive as Apple
-- event descriptors, so note text is never spliced into script source.

on listNotes()
	set out to {}
	tell application "Notes"
		repeat with acct in accounts
			set acctName to name of acct
			repeat with f in folders of acct
				my collectFolder(f, acctName, out)
			end repeat
		end repeat
	end tell
	return out
end listNotes

on collectFolder(f, acctName, out)
	tell application "Notes"
		set end of out to {acctName, name of f, id of notes of f, name of notes of f, creation date of notes of f, modification date of notes of f, password protected of notes of f}
		repeat with subfolder in folders of f
			my collectFolder(subfolder, acctName, out)
		end repeat
	end tell
end collectFolder

on plaintextOf(noteIDs)
	set out to {}
	tell application "Notes"
		repeat with noteID in noteIDs
			try
				set theNote to note id (noteID as text)
				if not (password protected of theNote) then
					set end of out to {noteID as text, plaintext of theNote}
				end if
			end try
		end repeat
	end tell
	return out
end plaintextOf

on targetAccount()
	tell application "Notes"
		if exists account "iCloud" then return account "iCloud"
		return default account
	end tell
end targetAccount

on createNote(folderName, html)
	tell application "Notes"
		set acct to my targetAccount()
		if not (exists folder folderName of acct) then
			make new folder at acct with properties {name:folderName}
		end if
		set theNote to make new note at folder folderName of acct with properties {body:html}
		return id of theNote
	end tell
end createNote

on setBody(noteID, html)
	tell application "Notes"
		set body of note id noteID to html
	end tell
	return true
end setBody
"""#
}
