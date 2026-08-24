#!/usr/bin/env python3
# tiktok_cleaner.py — раз в прогон смотрит профиль TikTok и:
#  - если пост опубликован (описание до '|' 1:1 = имя файла, без учёта регистра) ->
#    удаляет файл из репо videos/ и убирает из drafts.md / drafts_state.json
#  - ничего не заливает, только чистит
import os, sys, json, time, base64, subprocess, urllib.request, urllib.error, urllib.parse

GH_REPO  = os.environ.get("GH_REPO", "minecraftwiki-xyz/video-tiktok")
GH_TOKEN = os.environ.get("GH_TOKEN", "")
TIKTOK_USER = os.environ.get("TIKTOK_USER", "newora_")
HASHTAGS = "#cs2 #youtube #video"
STATE_PATH, LIST_PATH = "drafts_state.json", "drafts.md"

def gh(method, path, body=None, nf=False):
    req = urllib.request.Request(f"https://api.github.com/repos/{GH_REPO}{path}", method=method)
    req.add_header("Authorization", f"Bearer {GH_TOKEN}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "tiktok-cleaner")
    data = json.dumps(body).encode() if body is not None else None
    if data: req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, data=data, timeout=300) as r:
            return json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        if nf and e.code == 404: return None
        raise

def get_file(path):
    it = gh("GET", f"/contents/{path}", nf=True)
    if not it: return None
    try: return json.loads(base64.b64decode(it["content"]).decode())
    except Exception: return None

def put_file(path, text, msg):
    body = {"message": msg, "content": base64.b64encode(text.encode()).decode()}
    for attempt in range(3):
        cur = gh("GET", f"/contents/{path}", nf=True)
        if cur: body["sha"] = cur["sha"]
        try:
            gh("PUT", f"/contents/{path}", body); return
        except urllib.error.HTTPError as e:
            if e.code == 409:
                time.sleep(2); continue
            raise
    print(f"warn: put {path} законфликтовал, пропуск")

def stem_of(name):
    return name[:-4] if name.lower().endswith(".mp4") else name

def profile_heads():
    out = subprocess.run(["yt-dlp", "--flat-playlist", "-J", "--no-warnings",
                          f"https://www.tiktok.com/@{TIKTOK_USER}"],
                         capture_output=True, text=True, timeout=240)
    if out.returncode != 0:
        return None
    entries = json.loads(out.stdout).get("entries") or []
    heads = set()
    for p in entries:
        t = (p.get("title") or "").strip()
        if t: heads.add(t.split("|")[0].strip().casefold())
    return heads

def main():
    if not GH_TOKEN:
        print("нет GH_TOKEN"); return 0
    try:
        heads = profile_heads()
    except Exception as e:
        print("профиль недоступен:", e); return 0
    if not heads:
        print("профиль пуст/не отдался — пропуск прогона"); return 0
    print(f"постов на профиле с описанием: {len(heads)}")

    listing = gh("GET", "/contents/videos") or []
    sha_map = {it["name"]: it["sha"] for it in listing
               if it.get("type") == "file" and it["name"].lower().endswith(".mp4")}

    state = get_file(STATE_PATH)
    if not isinstance(state, dict) or not isinstance(state.get("items"), list):
        state = {"items": [], "bad": {}, "posted": [], "pids": {}, "cooldown_until": 0}
    state.setdefault("posted", []); state.setdefault("pids", {})

    removed = []
    for name, sha in list(sha_map.items()):
        st = stem_of(name)
        if len(st) < 8: continue
        if st.casefold() in heads:
            print(f"опубликовано -> удаляю из репо: {name}")
            try:
                gh("DELETE", f"/contents/videos/{urllib.parse.quote(name)}",
                   {"message": f"published: {name}", "sha": sha})
                removed.append(name)
            except urllib.error.HTTPError as e:
                print("  DELETE не прошёл:", e.code)

    # те, что уже пропали из репо ранее, но вдруг висят в списке черновиков — тоже чистим
    for name in list(state["items"]):
        st = stem_of(name)
        if len(st) >= 8 and st.casefold() in heads and name not in removed:
            print(f"пропадает из списка (файла уже нет): {name}")
            removed.append(name)

    if removed:
        state["items"] = [n for n in state["items"] if n not in removed]
        for n in removed:
            state["pids"].pop(n, None)
            state["posted"].append(n)
        state["posted"] = state["posted"][-300:]
        put_file(STATE_PATH, json.dumps(state, ensure_ascii=False), "cleaner: -опубликованные")
        lines = [f"{i}. {stem_of(n)} | {HASHTAGS}" for i, n in enumerate(state["items"], 1)]
        put_file(LIST_PATH, "\n".join(lines) + "\n", f"cleaner list ({len(lines)})")
        print(f"убрано {len(removed)}: {[n[:40] for n in removed]}")
    else:
        print("новых опубликованных нет")
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print("ОШИБКА cleaner (не страшно):", e)
        sys.exit(0)
