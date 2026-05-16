on run argv
    set platformType to "ios"
    if (count of argv) > 0 then
        set platformType to item 1 of argv
    end if

    tell application "Xcode"
        set myDoc to active workspace document

        set destinationFound to false
        set allDestinations to run destinations of myDoc

        repeat with aDest in allDestinations
            set destinationName to name of aDest

            if platformType is "ios" then
                if destinationName contains "iPhone" or destinationName contains "iPad" then
                    set active run destination of myDoc to aDest
                    set destinationFound to true
                    exit repeat
                end if
            else if platformType is "macos" then
                if destinationName is "My Mac" then
                    set active run destination of myDoc to aDest
                    set destinationFound to true
                    exit repeat
                end if
            else
                return "Error: Unknown platform " & platformType
            end if
        end repeat

        if not destinationFound then
            if platformType is "ios" then
                return "Error: iOS simulator destination not found. Create an iPhone or iPad simulator first."
            end if
            return "Error: Destination not found for platform: " & platformType
        end if

        set actionResult to test myDoc

        repeat until completed of actionResult is true
            delay 1
        end repeat

        set finalStatus to status of actionResult

        if finalStatus is succeeded then
            return "success"

        else if finalStatus is failed or finalStatus is |error occurred| then
            set failureMessages to {}

            repeat with aFailure in every test failure of actionResult
                set msg to message of aFailure
                set fPath to file path of aFailure
                set lNum to starting line number of aFailure

                if fPath is not missing value then
                    set end of failureMessages to "Test Failure: " & msg & " (File: " & fPath & " Line: " & lNum & ")"
                else
                    set end of failureMessages to "Test Failure: " & msg
                end if
            end repeat

            repeat with anError in every build error of actionResult
                set msg to message of anError
                set fPath to file path of anError
                set lNum to starting line number of anError

                if fPath is not missing value then
                    set end of failureMessages to "Build Error: " & msg & " (File: " & fPath & " Line: " & lNum & ")"
                else
                    set end of failureMessages to "Build Error: " & msg
                end if
            end repeat

            if (count of failureMessages) > 0 then
                set AppleScript's text item delimiters to return
                set resultString to failureMessages as string
                set AppleScript's text item delimiters to ""
                error resultString number 1
            else
                set fallbackMsg to error message of actionResult
                if fallbackMsg is missing value then set fallbackMsg to "Unknown test error occurred."
                error fallbackMsg number 1
            end if

        else if finalStatus is cancelled then
            return "Test was cancelled."
        else
            error "Test ended with status: " & (finalStatus as string) number 1
        end if
    end tell
end run
