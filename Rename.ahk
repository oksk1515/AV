#Requires AutoHotkey v2.0
#SingleInstance Force

; 1. 분리된 NamingEngine 로드 (NamingEngine 내부에서 Scraper와 Database를 자동 include함)
#Include "NamingEngine.ahk"

; 2. GUI 생성
guiMain := Gui("+AlwaysOnTop", "AV 파일명 일괄 변경기 (MAXJAV + JAVGURU 폴백)")
guiMain.SetFont("s9", "맑은 고딕")

guiMain.Add("Text", "w460", "동영상 파일 또는 폴더를 드래그 앤 드롭하세요.")
edtFiles := guiMain.Add("Edit", "w460 h180 -Wrap HScroll", "")
btnRun := guiMain.Add("Button", "w460 h32 Default", "파일명 일괄 변경 실행")

txtStatus := guiMain.Add("Text", "w460 cBlue", "대기 중...")
bar := guiMain.Add("Progress", "w460 h20 Range0-100", 0)
txtLog := guiMain.Add("Edit", "w460 h150 ReadOnly", "")

guiMain.OnEvent("DropFiles", OnDropFiles)
btnRun.OnEvent("Click", OnClickRun)
guiMain.OnEvent("Close", (*) => ExitApp())
guiMain.Show()

; --- 드래그 앤 드롭 이벤트 ---
OnDropFiles(guiObj, ctrlObj, fileArray, x, y) {
    fileListText := ""
    for itemPath in fileArray {
        cleanPath := Trim(itemPath, " `t`r`n")
        if DirExist(cleanPath) {
            ; 폴더 하위 탐색
            Loop Files, cleanPath . "\*.*", "R" {
                if RegExMatch(A_LoopFileExt, "i)^(mp4|mkv|avi|wmv)$")
                    fileListText .= A_LoopFilePath . "`r`n"
            }
        } else {
            ; 단일 파일
            SplitPath(cleanPath, , , &ext)
            if RegExMatch(ext, "i)^(mp4|mkv|avi|wmv)$")
                fileListText .= cleanPath . "`r`n"
        }
    }
    
    if (edtFiles.Value != "")
        edtFiles.Value := RTrim(edtFiles.Value, "`r`n") . "`r`n" . fileListText
    else
        edtFiles.Value := fileListText
}

; --- 일괄 실행 이벤트 ---
OnClickRun(*) {
    rawText := Trim(edtFiles.Value)
    if (rawText == "") {
        MsgBox("변경할 파일 목록이 비어 있습니다.", "알림")
        return
    }

    lines := []
    seen := Map()
    seen.CaseSense := false
    for line in StrSplit(rawText, "`n", "`r") {
        t := Trim(line, " `t`r`n")
        if (t != "" && FileExist(t) && !DirExist(t) && !seen.Has(t)) {
            SplitPath(t, , , &ext)
            if RegExMatch(ext, "i)^(mp4|mkv|avi|wmv)$") {
                lines.Push(t)
                seen[t] := true
            }
        }
    }

    if (lines.Length == 0) {
        MsgBox("유효한 동영상 파일이 없습니다.", "알림")
        return
    }

    clipSaved := ClipboardAll()
    btnRun.Enabled := false
    edtFiles.Enabled := false
    bar.Value := 0
    bar.Opt("+Range0-" . lines.Length)
    
    success := 0
    fail := 0
    skip := 0

    UpdateStatus(msg) {
        txtStatus.Text := msg
    }

    try {
        ActressDatabase.Load(true)
        for idx, filePath in lines {
            SplitPath(filePath, &oldFileName, &dir)
            txtStatus.Text := "(" . idx . "/" . lines.Length . ") 처리 중: " . oldFileName
            bar.Value := idx

            ; NamingEngine을 통해 표준 이름 파싱 및 웹 검색(MAXJAV -> JAVGURU)
            try {
                newFileName := NamingEngine.ProcessFileName(oldFileName, UpdateStatus)
                if RegExMatch(newFileName, '[<>:"/\\|?*\x00-\x1F]')
                    throw Error("파일명에 사용할 수 없는 문자가 있습니다.")
            } catch as err {
                txtLog.Value := "[실패] " . oldFileName . " : " . err.Message . "`r`n" . txtLog.Value
                fail++
                continue
            }

            if (newFileName != "" && newFileName != oldFileName) {
                newFilePath := dir . "\" . newFileName
                try {
                    FileMove(filePath, newFilePath, 0)
                    txtLog.Value := "[성공] " . oldFileName . " -> " . newFileName . "`r`n" . txtLog.Value
                    success++
                } catch as err {
                    txtLog.Value := "[실패] " . oldFileName . " (원인: " . err.Message . ")`r`n" . txtLog.Value
                    fail++
                }
            } else {
                txtLog.Value := "[스킵/일치] " . oldFileName . "`r`n" . txtLog.Value
                skip++
            }

            Sleep(30)
        }

    } catch as err {
        txtStatus.Text := "작업 중단: " . err.Message
        MsgBox(err.Message, "작업 오류")
        return
    } finally {
        btnRun.Enabled := true
        edtFiles.Enabled := true
        A_Clipboard := clipSaved
    }

    txtStatus.Text := "완료: 성공 " . success . "건 / 스킵 " . skip . "건 / 실패 " . fail . "건"
    btnRun.Enabled := true
    edtFiles.Enabled := true
    MsgBox("처리가 완료되었습니다.`n성공: " . success . "개`n스킵: " . skip . "개`n실패: " . fail . "개", "완료")
}
