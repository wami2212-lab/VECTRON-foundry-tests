import glob, json, re

names = json.load(open("error_map.json"))
pat = re.compile(r'vm\.expectRevert\(\s*(?:bytes\(\s*)?"((?:[^"\\]|\\.)*)"\s*\)?\s*\)')
left = set()
total = 0
for path in glob.glob("test/*.sol"):
    if path.endswith("mainnet_verified.sol"):
        continue
    text = open(path, encoding="utf-8", newline="").read()

    def sub(m):
        global total
        msg = m.group(1)
        if msg in names:
            total += 1
            return 'vm.expectRevert(bytes4(keccak256("%s()")))' % names[msg]
        left.add(msg)
        return m.group(0)

    new = pat.sub(sub, text)
    if new != text:
        open(path, "w", encoding="utf-8", newline="").write(new)
print("updated", total, "expectRevert calls")
for msg in sorted(left):
    print("left unchanged (not a VECTRON message):", msg)
