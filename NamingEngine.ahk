#Requires AutoHotkey v2.0
#Include "BrowserScraper.ahk"
#Include "ActressDatabase.ahk"

class NamingEngine {
    static ProcessFileName(fileName, statusCallback := "") {
        SplitPath(fileName, , , &ext, &nameNoExt)
        extDot := (ext != "") ? ("." . ext) : ""
        dbData := ActressDatabase.Load()

        ; 품번 추출
        cleanDvdId := ""
        if RegExMatch(nameNoExt, "i)(?<![A-Z0-9])([0-9]?[A-Z]{2,7})[-_ ]?(\d{2,5})(?![A-Z0-9])", &mDvd)
            cleanDvdId := StrUpper(mDvd[1]) . "-" . mDvd[2]

        resolvedActress := ""

        ; [A] 품번 기반
        if (cleanDvdId != "") {
            if dbData.knownDvdMap.Has(cleanDvdId)
                resolvedActress := dbData.knownDvdMap[cleanDvdId]

            if (resolvedActress == "")
                resolvedActress := this.FindInName(nameNoExt, dbData)

            if (resolvedActress == "") {
                resolvedActress := this.SearchOnline(cleanDvdId, statusCallback)
                if (resolvedActress != "") {
                    resolvedActress := ActressDatabase.ApplyAlias(resolvedActress, dbData)
                    resolvedActress := this.NormalizeOrder(resolvedActress, dbData)
                    ActressDatabase.SaveDvd(cleanDvdId, resolvedActress)
                }
            }

            if (resolvedActress == "") {
                ActressDatabase.LogMissing(cleanDvdId, fileName)
                return fileName
            }
        }
        ; [B] 배우 이름 기반
        else {
            knownName := this.FindInName(nameNoExt, dbData)
            if (knownName == "")
                return fileName
            rawName := knownName
            if (rawName == "")
                return fileName

            searchName := dbData.koToEng.Has(rawName) ? dbData.koToEng[rawName] : rawName
            searchName := ActressDatabase.ApplyAlias(searchName, dbData)
            resolvedActress := this.NormalizeOrder(searchName, dbData, true, statusCallback)
            return resolvedActress . extDot
        }

        resolvedActress := ActressDatabase.ApplyAlias(resolvedActress, dbData)

        ; Keep all recognized tags, especially disc/part identifiers.
        tags := "", seen := Map(), pos := 1
        pattern := "i)(?<![A-Z0-9])(?:VR|4K|8K|FHD|UHD|CD[-_ ]?\d+|PART[-_ ]?\d+|DIS[CK][-_ ]?\d+)(?![A-Z0-9])"
        while RegExMatch(nameNoExt, pattern, &tag, pos) {
            value := RegExReplace(StrUpper(tag[0]), "[-_ ]", "")
            if !seen.Has(value) {
                tags .= " " . value
                seen[value] := true
            }
            pos := tag.Pos + tag.Len
        }
        ; Preserve numeric split suffixes such as ABC-123-1 and ABC-123_02.
        splitPattern := "i)(?<![A-Z0-9])" . StrReplace(cleanDvdId, "-", "[-_ ]?") . "[-_]([0-9]{1,2})(?![A-Z0-9])"
        if RegExMatch(nameNoExt, splitPattern, &splitPart) {
            part := "PART" . splitPart[1]
            if !seen.Has(part)
                tags .= " " . part
        }
        return resolvedActress . " " . cleanDvdId . tags . extDot
    }

    static SearchOnline(dvdId, statusCallback := "") {
        hwnd := BrowserScraper.EnsureBrowserReady()
        if (!hwnd)
            return ""

        if (statusCallback != "")
            statusCallback("1차: MAXJAV 검색 중 [" . dvdId . "]...")
        firstError := ""
        act := ""
        try act := BrowserScraper.QueryMaxjav(hwnd, dvdId)
        catch as err
            firstError := err.Message

        if (act == "") {
            if (statusCallback != "")
                statusCallback("2차: JAVGURU 상세글 진입 중 [" . dvdId . "]...")
            try act := BrowserScraper.QueryJavguruDetail(hwnd, dvdId)
            catch as err
                throw Error("웹 조회 실패: " . firstError . " / " . err.Message)
            if (act == "" && firstError != "")
                throw Error("MAXJAV 조회 실패: " . firstError)
        }
        return act
    }

    static NormalizeOrder(name, dbData, queryOnline := false, statusCallback := "") {
        key := ActressDatabase.GetSortKey(name)
        if (key == "")
            return name
        if dbData.standardOrderMap.Has(key)
            return dbData.standardOrderMap[key]

        if (queryOnline) {
            hwnd := BrowserScraper.EnsureBrowserReady()
            if (hwnd) {
                if (statusCallback != "")
                    statusCallback("기준 표기 확인 중 [" . name . "]...")
                BrowserScraper.Navigate(hwnd, "https://maxjav.com/?s=" . StrReplace(name, " ", "+"))
                txt := BrowserScraper.FetchText(hwnd)
                tokens := StrSplit(name, [" ", "_"])
                if (tokens.Length == 2) {
                    c1 := BrowserScraper.CountRegex(txt, "i)\b" . BrowserScraper.EscapeRegex(tokens[1]) . "\s+" . BrowserScraper.EscapeRegex(tokens[2]) . "\b")
                    c2 := BrowserScraper.CountRegex(txt, "i)\b" . BrowserScraper.EscapeRegex(tokens[2]) . "\s+" . BrowserScraper.EscapeRegex(tokens[1]) . "\b")
                    if (c2 > c1)
                        name := BrowserScraper.FormatWord(tokens[2]) . " " . BrowserScraper.FormatWord(tokens[1])
                }
            }
        }

        ActressDatabase.SaveActress(name)
        dbData.standardOrderMap[key] := name
        return name
    }

    static FindInName(nameNoExt, dbData) {
        lower := StrLower(RegExReplace(nameNoExt, "_", " "))
        best := ""
        for act in dbData.orderList {
            if (BrowserScraper.MatchesName(lower, act) && StrLen(act) > StrLen(best))
                best := act
        }
        if (best != "")
            return ActressDatabase.ApplyAlias(best, dbData)
        for ko, eng in dbData.koToEng {
            if InStr(nameNoExt, ko)
                return ActressDatabase.ApplyAlias(eng, dbData)
        }
        return ""
    }
}