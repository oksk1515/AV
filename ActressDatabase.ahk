#Requires AutoHotkey v2.0

class ActressDatabase {
    static iniPath := A_ScriptDir . "\ActressDB.ini"
    static missingIniPath := A_ScriptDir . "\MissingDB.ini"

    static cache := 0

    static Load(refresh := false) {
        if (!refresh && IsObject(this.cache))
            return this.cache
        data := {
            koToEng: Map(),
            knownDvdMap: Map(),
            standardOrderMap: Map(),
            aliasMap: Map(),
            orderList: []
        }

        if !FileExist(this.iniPath) {
            this.InitFile()
            return this.Load(true)
        }

        this.EnsureIniEncoding(this.iniPath)
        content := ""
        for section in ["KoreanToEng", "AliasToCanonical", "KnownDvdId", "StandardNames"] {
            content .= "[" . section . "]`n" . IniRead(this.iniPath, section, , "") . "`n"
        }

        sec := ""
        for line in StrSplit(content, "`n", "`r") {
            t := Trim(line)
            if (t == "" || SubStr(t, 1, 1) == ";")
                continue

            if RegExMatch(t, "^\[\s*(.*?)\s*\]$", &sm) {
                sec := StrLower(sm[1])
                continue
            }

            if InStr(t, "=") {
                parts := StrSplit(t, "=", , 2)
                k := Trim(parts[1]), v := Trim(parts[2])

                if ((sec == "koreantoeng" || sec == "standardnames") && k != "" && v != "") {
                    if (sec == "koreantoeng")
                        data.koToEng[k] := v
                    key := this.GetSortKey(v)
                    if (key != "" && !data.standardOrderMap.Has(key)) {
                        data.standardOrderMap[key] := v
                        data.orderList.Push(v)
                    }
                } else if (sec == "aliastocanonical" && k != "" && v != "") {
                    data.aliasMap[this.GetSortKey(k)] := v
                } else if (sec == "knowndvdid" && k != "" && v != "") {
                    data.knownDvdMap[StrUpper(k)] := v
                    for act in StrSplit(v, ",") {
                        cAct := Trim(act)
                        key := this.GetSortKey(cAct)
                        if (key != "" && !data.standardOrderMap.Has(key)) {
                            data.standardOrderMap[key] := cAct
                            data.orderList.Push(cAct)
                        }
                    }
                }
            }
        }
        this.cache := data
        return data
    }

    static InitFile() {
        if FileExist(this.iniPath)
            return
        f := FileOpen(this.iniPath, "w", "UTF-16")
        f.Write("[KoreanToEng]`r`n[AliasToCanonical]`r`n[KnownDvdId]`r`n[StandardNames]`r`n")
        f.Close()
    }

    ; Windows IniRead/IniWrite use UTF-16 or the system code page, not UTF-8.
    ; Convert BOM-marked UTF-8 only, after preserving an exact backup.
    static EnsureIniEncoding(path) {
        if !FileExist(path) {
            f := FileOpen(path, "w", "UTF-16")
            f.Close()
            return
        }
        f := FileOpen(path, "r")
        raw := Buffer(3, 0)
        f.Pos := 0
        count := f.RawRead(raw, 3)
        f.Close()
        if (count < 3 || NumGet(raw, 0, "UChar") != 0xEF
            || NumGet(raw, 1, "UChar") != 0xBB || NumGet(raw, 2, "UChar") != 0xBF)
            return
        backup := path . ".utf8-backup-" . A_Now . "-" . A_TickCount
        FileCopy(path, backup, 0)
        temp := backup . ".tmp"
        try {
            text := FileRead(path, "UTF-8")
            out := FileOpen(temp, "w", "UTF-16")
            out.Write(text)
            out.Close()
            FileMove(temp, path, 1)
        } finally {
            if FileExist(temp)
                FileDelete(temp)
        }
    }

    static ApplyAlias(name, dbData) {
        key := this.GetSortKey(name)
        return dbData.aliasMap.Has(key) ? dbData.aliasMap[key] : name
    }

    static SaveDvd(dvdId, actressName) {
        IniWrite(actressName, this.iniPath, "KnownDvdId", dvdId)
        if IsObject(this.cache)
            this.cache.knownDvdMap[StrUpper(dvdId)] := actressName
        ; Missing-log cleanup must not hide a successful database write.
        try IniDelete(this.missingIniPath, "MissingList", dvdId)
    }

    static SaveActress(actressName) {
        key := this.GetSortKey(actressName)
        IniWrite(actressName, this.iniPath, "StandardNames", key)
        if IsObject(this.cache) {
            if !this.cache.standardOrderMap.Has(key)
                this.cache.orderList.Push(actressName)
            this.cache.standardOrderMap[key] := actressName
        }
    }

    static LogMissing(idKey, fileName) {
        this.EnsureIniEncoding(this.missingIniPath)
        IniWrite(fileName, this.missingIniPath, "MissingList", idKey)
    }

    static GetSortKey(name) {
        words := []
        for w in StrSplit(StrLower(name), [" ", "_", "-"]) {
            cw := Trim(w)
            if (cw != "")
                words.Push(cw)
        }
        if (words.Length <= 1)
            return (words.Length == 1) ? words[1] : ""

        n := words.Length
        Loop n {
            i := A_Index
            Loop n - i {
                j := A_Index
                if (StrCompare(words[j], words[j + 1]) > 0) {
                    tmp := words[j], words[j] := words[j + 1], words[j + 1] := tmp
                }
            }
        }
        res := ""
        for w in words
            res .= (res == "" ? "" : "_") . w
        return res
    }
}