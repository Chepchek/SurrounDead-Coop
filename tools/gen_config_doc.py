# Writes docs/CONFIG.md (Russian settings table) from SCHEMA in sdc_config.lua.
# usage: python -I tools/gen_config_doc.py <scripts dir> <out .md>
import re
import sys

BS = chr(92)
scripts, outp = sys.argv[1], sys.argv[2]
src = open(scripts + "/sdc_config.lua", encoding="utf-8").read()
body = src[src.index("local SCHEMA = {"):]
body = body[:body.index("\n}\n")]
row_re = re.compile(r'\{\s*"([a-z0-9_]+)",\s*"(\w+)",\s*(.+?),\s*"((?:[^"' + BS + BS + r']|' + BS + BS + r'.)*)"\s*\}')
rows = row_re.findall(body)
path = BS.join(["SurrounDead", "Binaries", "Win64", "ue4ss", "Mods", "SDCoop", "config.ini"])
out = [
    "# Настройки SDCoop",
    "",
    "Все настройки лежат в `" + path + "` (строки `ключ = значение`).",
    "Файл создаётся при первом запуске; часть настроек меняется в игре (главное меню → «Кооператив» или панель F7).",
    "Править руками — только при закрытой игре. Ключи, которых нет в файле, берут значение по умолчанию.",
    "",
    "Таблица собрана из `SCHEMA` в `mods/SDCoop/scripts/sdc_config.lua` (там же порядок записи в файл).",
    "",
    "| Ключ | Тип | По умолчанию | Что делает |",
    "|---|---|---|---|",
]
for key, typ, default, desc in rows:
    default = default.strip()
    default = "(пусто)" if default == '""' else default.strip('"')
    out.append("| `%s` | %s | `%s` | %s |" % (key, typ, default, desc.replace("|", BS + "|")))
with open(outp, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(out) + "\n")
print(len(rows), "settings")
