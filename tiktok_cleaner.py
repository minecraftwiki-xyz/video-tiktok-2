#!/usr/bin/env python3
# tiktok_cleaner.py — проверка залитых + синхронизация processed.txt между репо.
#  - профиль TikTok: описание до '|' 1:1 (регистр не важен) = имя файла -> удаляет videos/<name>
#  - processed.txt: объединение между GH_REPO и PEER_REPO (пишет только если изменилось)
import os, sys, json, time, base64, subprocess, urllib.request, urllib.error, urllib.parse

GH_TOKEN = os.environ.get("GH_TOKEN", "")
GH_REPO  = os.environ.get("GH_REPO", "minecraftwiki-xyz/video-tiktok")
PEER_REPO = os.environ.get("PEER_REPO", "")
TIKTOK_USER = os.environ.get("TIKTOK_USER", "newora_")

def gh(method, path, body=None, nf=False, repo=None):
    req = urllib.request.Request(f"https://api.github.com/repos/{repo or GH_REPO}{path}", method=method)
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

def get_text(path, repo=None):
    it = gh("GET", f"/contents/{path}", nf=True, repo=repo)
    if not it: return None
    try: return base64.b64decode(it["content"]).decode()
    except Exception: return None

def get_json(path):
    t = get_text(path)
    try: return json.loads(t) if t else None
    except Exception: return None

def put_text(path, text, msg, repo=None):
    body = {"message": msg, "content": base64.b64encode(text.encode()).decode()}
    for attempt in range(3):
        cur = gh("GET", f"/contents/{path}", nf=True, repo=repo)
        if cur: body["sha"] = cur["sha"]
        try:
            gh("PUT", f"/contents/{path}", body, repo=repo); return True
        except urllib.error.HTTPError as e:
            if e.code == 409:
                time.sleep(2); continue
            print(f"warn: put {path} HTTP {e.code}"); return False
    print(f"warn: put {path} законфликтовал"); return False

def stem_of(name):
    return name[:-4] if name.lower().endswith(".mp4") else name

def sync_processed():
    if not PEER_REPO: return
    a = get_text("processed.txt") or ""
    b = get_text("processed.txt", repo=PEER_REPO) or ""
    A = a.splitlines()
    uset = set(A)
    union = "\n".join(A + [l for l in b.splitlines() if l not in uset])
    union = union + "\n" if union else ""
    n_a, n_b = len(A), len(b.splitlines())
    n_u = len(union.splitlines())
    if n_u > n_a:
        put_text("processed.txt", union, f"sync processed: ∪{n_u} (+{n_u-n_a})", )
        print(f"processed: {GH_REPO} {n_a} -> {n_u}")
    if n_u > n_b:
        put_text("processed.txt", union, f"sync processed: ∪{n_u} (+{n_u-n_b})", repo=PEER_REPO)
        print(f"processed: {PEER_REPO} {n_b} -> {n_u}")
    if n_u == n_a == n_b:
        print(f"processed: синхронно ({n_a})")

def purge_peer_dupes():
    """Ферма-2: удаляет из своего videos/ файлы, которые уже есть в videos/ пир-репо."""
    if os.environ.get("PURGE_PEER_DUPES") != "1" or not PEER_REPO:
        return
    mine = gh("GET", "/contents/videos") or []
    peer = gh("GET", "/contents/videos", repo=PEER_REPO) or []
    pnames = {x["name"] for x in peer if x.get("type") == "file"}
    n = 0
    for it in mine:
        if it.get("type") == "file" and it["name"] in pnames:
            print("уже есть в основном -> удаляю из копии:", it["name"])
            try:
                gh("DELETE", f"/contents/videos/{urllib.parse.quote(it['name'])}",
                   {"message": f"dup of main repo: {it['name']}", "sha": it["sha"]})
                n += 1
            except urllib.error.HTTPError as e:
                print("  DELETE не прошёл:", e.code)
    print(f"пир-дедуп: удалено {n}" if n else "пир-дедуп: чисто")

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
        sync_processed()
    except Exception as e:
        print("processed sync упал (не страшно):", e)
    try:
        purge_peer_dupes()
    except Exception as e:
        print("пир-дедуп упал (не страшно):", e)
    try:
        heads = profile_heads()
    except Exception as e:
        print("профиль недоступен:", e); return 0
    if not heads:
        print("профиль пуст/не отдался — пропуск"); return 0
    print(f"@{TIKTOK_USER}: постов с описанием: {len(heads)}")

    listing = gh("GET", "/contents/videos") or []
    removed = 0
    for it in listing:
        if it.get("type") != "file" or not it["name"].lower().endswith(".mp4"): continue
        st = stem_of(it["name"])
        if len(st) < 8: continue
        if st.casefold() in heads:
            print(f"опубликовано -> удаляю: {it['name']}")
            try:
                gh("DELETE", f"/contents/videos/{urllib.parse.quote(it['name'])}",
                   {"message": f"published: {it['name']}", "sha": it["sha"]})
                removed += 1
            except urllib.error.HTTPError as e:
                print("  DELETE не прошёл:", e.code)
    print("готово:", f"удалено {removed}" if removed else "новых опубликованных нет")
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print("ОШИБКА cleaner (не страшно):", e)
        sys.exit(0)
