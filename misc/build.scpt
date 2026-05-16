on run argv
    -- 引数がない場合のデフォルト設定
    set platformType to "ios"
    if (count of argv) > 0 then
        set platformType to item 1 of argv
    end if

    tell application "Xcode"
        set myDoc to active workspace document

        -- 引数によってスキームとデバイスを切り替え
        if platformType is "ios" then
            set targetDeviceName to "Any iOS Device (arm64)"
        else if platformType is "macos" then
            set targetDeviceName to "My Mac"
        else
            return "Error: Unknown platform " & platformType
        end if

        -- デバイス（Run Destination）の設定
        set allDestinations to run destinations of myDoc
        set destinationFound to false
        repeat with aDest in allDestinations
            if name of aDest is targetDeviceName then
                set active run destination of myDoc to aDest
                set destinationFound to true
                exit repeat
            end if
        end repeat

        if not destinationFound then return "Error: Destination not found: " & targetDeviceName

        -- ビルド実行
        set actionResult to build myDoc

        repeat until completed of actionResult is true
            delay 1
        end repeat

        -- 4. 結果の判定
        set finalStatus to status of actionResult

        -- 5. issue の収集（error / warning / analyzer）
        set issueMessages to {}

        set allErrors to every build error of actionResult
        repeat with anError in allErrors
            set msg to message of anError
            set fPath to file path of anError
            set lNum to starting line number of anError

            if fPath is not missing value then
                set end of issueMessages to "Error: " & msg & " (File: " & fPath & " Line: " & lNum & ")"
            else
                set end of issueMessages to "Error: " & msg
            end if
        end repeat

        set allWarnings to every build warning of actionResult
        repeat with aWarning in allWarnings
            set msg to message of aWarning
            set fPath to file path of aWarning
            set lNum to starting line number of aWarning

            if fPath is not missing value then
                set end of issueMessages to "Warning: " & msg & " (File: " & fPath & " Line: " & lNum & ")"
            else
                set end of issueMessages to "Warning: " & msg
            end if
        end repeat

        set allAnalyzerIssues to every analyzer issue of actionResult
        repeat with anAnalyzerIssue in allAnalyzerIssues
            set msg to message of anAnalyzerIssue
            set fPath to file path of anAnalyzerIssue
            set lNum to starting line number of anAnalyzerIssue

            if fPath is not missing value then
                set end of issueMessages to "Analyzer: " & msg & " (File: " & fPath & " Line: " & lNum & ")"
            else
                set end of issueMessages to "Analyzer: " & msg
            end if
        end repeat

        if finalStatus is succeeded then
            if (count of issueMessages) > 0 then
                set AppleScript's text item delimiters to linefeed
                set resultString to issueMessages as string
                set AppleScript's text item delimiters to ""
                return resultString & linefeed & "build success"
            else
                return "build success"
            end if

        else if finalStatus is failed or finalStatus is |error occurred| then
            if (count of issueMessages) > 0 then
                set AppleScript's text item delimiters to linefeed
                set resultString to issueMessages as string
                set AppleScript's text item delimiters to ""
                error resultString number 1
            else
                set fallbackMsg to error message of actionResult
                if fallbackMsg is missing value then set fallbackMsg to "Unknown build error occurred."
                error fallbackMsg number 1
            end if

        else if finalStatus is cancelled then
            return "Build was cancelled."
        else
            error "Build ended with status: " & (finalStatus as string) number 1
        end if
    end tell
end run
