#Requires AutoHotkey v2.0
#SingleInstance Force
#Include "BrowserScraper.ahk"
#Include "ActressDatabase.ahk"

iniPath := A_ScriptDir . "\ActressDB.ini"
InitDatabaseFile(iniPath)

; 1. DB 메모리 캐시 로드
koToEng := Map()
knownActresses := Map() ; Key: 정렬된 토큰 키, Value: 표준 표기명
existingDvdMap := Map()

LoadDatabase()

; 2. 컨트롤 패널 UI 생성
mainGui := Gui("+AlwaysOnTop", "통합 DB 수집기 (MAXJAV 기준)")
mainGui.SetFont("s10", "맑은 고딕")

mainGui.Add("Text", "w460", "품번(예: ACHJ-094) 또는 배우 이름(한글/영문) 입력:")
edtInput := mainGui.Add("Edit", "w340 r1", "")
btnStart := mainGui.Add("Button", "x+10 w110 h26 Default", "검색 및 수집")

txtStatus := mainGui.Add("Text", "xm y+15 w460 cBlue", "대기 중...")
txtLog := mainGui.Add("Edit", "xm w460 h280 ReadOnly", "")

btnStart.OnEvent("Click", (*) => ProcessInput())
mainGui.OnEvent("Close", (*) => ExitApp())
mainGui.Show()

; --- [메인 프로세스] 입력값 판별 및 분기 ---
ProcessInput() {
    rawVal := Trim(edtInput.Value)
    if (rawVal == "") {
        MsgBox("품번 또는 배우 이름을 입력해 주세요.", "알림")
        return
    }

    SetControls(false)
    clipSaved := ClipboardAll()
    try {
        LoadDatabase()
        txtStatus.Text := "브라우저 점검 중..."

        browserHwnd := EnsureBrowserReady()
        if (!browserHwnd) {
            MsgBox("브라우저(Edge/Chrome)를 활성화하지 못했습니다.", "오류")
            SetControls(true)
            return
        }

        ; 1) 품번 형식인지 확인 (예: ABC-123, 3DSVR-012, IPX123 등)
        if RegExMatch(rawVal, "i)^\[?([0-9]?[A-Z]{2,7})[-_ ]?(\d{2,5})\]?$", &m) {
            targetDvd := StrUpper(m[1]) . "-" . m[2]
            txtLog.Value := "▶ [모드: 품번 감지] " . targetDvd . " 조회 시작`r`n" . txtLog.Value
            HandleDvdInput(browserHwnd, targetDvd)
        } else {
            ; 2) 배우 이름 입력인 경우
            txtLog.Value := "▶ [모드: 배우 감지] '" . rawVal . "' 조회 시작`r`n" . txtLog.Value
            HandleActressInput(browserHwnd, rawVal)
        }

    } catch as err {
        txtLog.Value := "[오류] " . err.Message . "`r`n" . txtLog.Value
        txtStatus.Text := "오류로 중단됨"
    } finally {
        SetControls(true)
        A_Clipboard := clipSaved
    }
    edtInput.Focus()
}

; --- [모드 A] 품번 입력 처리 ---
HandleDvdInput(hwnd, dvdId) {
    global existingDvdMap, iniPath, txtStatus, txtLog

    ; 1. 기존 DB에 이미 등록되어 있는지 확인
    if existingDvdMap.Has(dvdId) {
        actress := existingDvdMap[dvdId]
        txtLog.Value := "ℹ [DB 캐시 확인] " . dvdId . " -> " . actress . "`r`n" . txtLog.Value
        RunFullScrape(hwnd, actress)
        return
    }

    ; 2. MAXJAV에서 품번 검색
    txtStatus.Text := "[" . dvdId . "] MAXJAV 검색 중..."
    NavigateTo(hwnd, "https://maxjav.com/?s=" . dvdId)
    pageText := FetchBrowserText(hwnd)

    if (pageText == "" || Is404(pageText)) {
        txtLog.Value := "❌ [" . dvdId . "] MAXJAV 검색 결과가 없습니다.`r`n" . txtLog.Value
        txtStatus.Text := "검색 결과 없음"
        return
    }

    ; 3. 품번 뒤에서 이름 추출 (1단어 vs 2단어 동적 판별)
    extractedName := ParseActressFromPage(pageText, dvdId)
    if (extractedName == "") {
        txtLog.Value := "❌ [" . dvdId . "] 페이지에서 배우 이름을 추출하지 못했습니다.`r`n" . txtLog.Value
        txtStatus.Text := "배우 추출 실패"
        return
    }

    ; 4. 이름 순서 정규화 및 표준화 (MAXJAV 기준 저장)
    resolvedName := ResolveAndRegisterActress(extractedName)

    ; 5. 품번-배우 매핑 저장
    SaveDvdToIni(dvdId, resolvedName)
    txtLog.Value := "★ [품번 등록] " . dvdId . " = " . resolvedName . "`r`n" . txtLog.Value

    ; 6. 해당 배우로 전수 수집 연계
    RunFullScrape(hwnd, resolvedName)
}

; --- [모드 B] 배우 이름 입력 처리 ---
HandleActressInput(hwnd, rawName) {
    global koToEng, txtLog

    ; 한글 이름일 경우 영문 매핑 확인
    searchName := koToEng.Has(rawName) ? koToEng[rawName] : rawName

    ; 이미 등록된 이름 순서를 재사용합니다. 미등록 입력은 검색어로만 사용합니다.
    resolvedName := ResolveAndRegisterActress(searchName)

    txtLog.Value := "★ [배우 정규화] 대상 이름: " . resolvedName . "`r`n" . txtLog.Value
    RunFullScrape(hwnd, resolvedName)
}

; --- [품번 뒤 이름 파싱 (1단어 / 2단어 판별)] ---
ParseActressFromPage(pageText, dvdId) {
    return BrowserScraper.ParseActressFromText(pageText, dvdId)
}

; --- [이름 정규화: 앞뒤 순서 도치(A B == B A) 판별 및 MAXJAV 표기 우선] ---
ResolveAndRegisterActress(inputName) {
    global knownActresses, iniPath

    sortKey := GetSortKey(inputName)
    if (sortKey == "")
        return inputName

    ; 기존에 등록된 순서가 있으면 그것을 반환
    if knownActresses.Has(sortKey) {
        return knownActresses[sortKey]
    }

    ; 검증되지 않은 검색어는 표준 이름으로 등록하지 않습니다.
    return inputName
}

; --- [전수 수집 (1p ~ 50p 크롤링 기존 로직)] ---
RunFullScrape(hwnd, targetActress) {
    global existingDvdMap, iniPath, txtStatus, txtLog

    tokens := []
    for w in StrSplit(targetActress, [" ", "_", "-"]) {
        cw := Trim(w)
        if (cw != "")
            tokens.Push(StrLower(cw))
    }

    encodedName := StrReplace(targetActress, " ", "+")
    foundDvdMap := Map()
    lastPageText := ""

    txtLog.Value := "▶ [" . targetActress . "] MAXJAV 1페이지부터 전수 수집 가동`r`n" . txtLog.Value

    Loop 50 {
        pageIndex := A_Index
        txtStatus.Text := "[" . targetActress . "] " . pageIndex . "페이지 수집 중..."

        targetUrl := (pageIndex == 1)
            ? "https://maxjav.com/?s=" . encodedName
            : "https://maxjav.com/?s=" . encodedName . "&paged=" . pageIndex

        NavigateTo(hwnd, targetUrl)
        pageText := WaitForSearchResultPage(hwnd, lastPageText, tokens, txtStatus)

        if Is404(pageText) {
            txtLog.Value := "[" . pageIndex . "p] 끝 페이지(404) 도달 -> 수집 종료`r`n" . txtLog.Value
            break
        }

        lastPageText := pageText
        pageLines := StrSplit(pageText, "`n", "`r")
        pageValidMatches := 0
        pageAdded := 0
        pageSkipped := 0
        pagePending := Map()

        patternDvd := "i)(?:\[)?\b([0-9]?[A-Z]{2,7})[-_ ]?(\d{2,5})(?:-[0-9A-Z]+)?\b"

        for rawLine in pageLines {
            lineStr := Trim(rawLine)
            if (lineStr == "")
                continue

            if RegExMatch(lineStr, "i)^(search|query|find|tag|category|view|filter)")
                continue

            if RegExMatch(lineStr, patternDvd, &m) {
                cleanId := StrUpper(m[1]) . "-" . m[2]
                if !IsValidDvd(m[1], m[2])
                    continue

                lowerLine := StrLower(lineStr)

                ; 1) 배우 이름 포함 여부 검증
                if !BrowserScraper.MatchesName(lineStr, targetActress)
                    continue

                pageValidMatches++

                ; 이미 존재하는 품번 제외
                if (existingDvdMap.Has(cleanId) || foundDvdMap.Has(cleanId)) {
                    pageSkipped++
                    continue
                }

                foundDvdMap[cleanId] := targetActress
                pagePending[cleanId] := targetActress
                pageAdded++
            }
        }

        for id, actress in pagePending
            SaveDvdToIni(id, actress)

        if (pageIndex > 1 && pageValidMatches == 0) {
            txtLog.Value := "[" . pageIndex . "p] 일치 품번 없음 -> 수집 종료`r`n" . txtLog.Value
            break
        }

        txtLog.Value := "[" . pageIndex . "p] 신규 " . pageAdded . "개 수집 (기존 " . pageSkipped . "개 제외)`r`n" . txtLog.Value

        Sleep(350)
    }

    count := foundDvdMap.Count

    txtLog.Value := "★ [" . targetActress . "] 완료: 총 " . count . "개 신규 품번 저장 완료`r`n`r`n" . txtLog.Value
    txtStatus.Text := "완료 (신규 " . count . "개 등록)"
}

; --- [INI 저장 및 DB 관리] ---
SaveDvdToIni(dvdId, actressName) {
    global existingDvdMap
    ActressDatabase.SaveDvd(dvdId, actressName)
    existingDvdMap[dvdId] := actressName
}

LoadDatabase() {
    global koToEng, knownActresses, existingDvdMap
    data := ActressDatabase.Load(true)
    koToEng := data.koToEng
    knownActresses := data.standardOrderMap
    existingDvdMap := data.knownDvdMap
}

InitDatabaseFile(path) {
    ActressDatabase.InitFile()
}

GetSortKey(name) {
    return ActressDatabase.GetSortKey(name)
}

NavigateTo(hwnd, url) {
    BrowserScraper.Navigate(hwnd, url)
}

FetchBrowserText(hwnd) {
    return BrowserScraper.FetchText(hwnd)
}

WaitForSearchResultPage(hwnd, prevText, tokens, statusCtrl) {
    Loop 3 {
        text := BrowserScraper.FetchText(hwnd)
        if (text != prevText || BrowserScraper.IsError(text))
            return text
        statusCtrl.Text := "페이지 전환 대기 중..."
        Sleep(700)
    }
    throw Error("페이지가 변경되지 않아 수집을 중단했습니다.")
}

EnsureBrowserReady() {
    return BrowserScraper.EnsureBrowserReady()
}

Is404(text) {
    return BrowserScraper.IsError(text)
}

IsValidDvd(prefix, num) {
    invalidWords := "i)^(PAGE|HTTP|HTTPS|UTF|TAG|POST|ENTRY|CONTENT|HEADER|FOOTER|COL|ROW|WIDTH|HEIGHT|ITEM|CLASS|JAV|MAXJAV|MKV|MP4|AVI|WMV|PART)$"
    if RegExMatch(prefix, invalidWords)
        return false
    return true
}

SetControls(state) {
    btnStart.Enabled := state
    edtInput.Enabled := state
}

Pause::Pause()
