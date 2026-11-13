# Contributing

**English** · [Русский](#как-помочь-проекту)

Thanks for helping. The most useful contributions are good bug reports from real co-op sessions, then small, tested fixes.

## Reporting a bug
1. Check that every player runs the same SDCoop version. It is in the co-op panel and in `UE4SS.log` as `[SNAP] head v=…`.
2. Use **Issues → New issue → Bug report**. The co-op panel's "Report a bug" button opens it with the version filled in.
3. Attach `UE4SS.log` from **both** the host and the client: `SurrounDead\Binaries\Win64\ue4ss\UE4SS.log`. The host's log is overwritten when the game restarts, so copy it right after the session.
4. Remove Steam IDs and anything else personal before posting.

One issue per problem, please. For ideas, use the feature request form.

## Changing the code
- Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first: the module map and the conventions. Its rules come from real crashes:
  - every engine call in `pcall`;
  - nothing but a flag change in a key bind;
  - no synchronous asset loads on clients;
  - one network message per batch, never one per world object;
  - a property the object lacks reads as a TrivialObject, not `nil`.
- Keep changes small and focused on one problem. Code comments and log lines are in English. On-screen text goes through `sdc_i18n.lua` in Russian and English.
- New settings go into the schema in `sdc_config.lua`, with a description. `docs/CONFIG.md` is generated from it.

## Tests
The mock tests run the real mod modules against a fake engine with Lua 5.4:

```bash
bash tools/run_tests.sh "$PWD/mods/SDCoop/scripts"
```

The script expects Lua 5.4 in `tools/lua54/` (`lua.exe`, `luac.exe`) and an **absolute** scripts path. GitHub Actions checks the syntax and accidental globals on every push and pull request (`.github/workflows/check.yml`).

Add a test for the bug you fix: a new `tests/mock_<topic>.lua` file that fails on the old code and passes on yours.

## Pull requests
- Describe what was broken, how you fixed it, and how you checked it: tests, and a co-op session if you could.
- Say whether the network message format changed. If it did, every player has to update together.
- By contributing you agree that your work is released under this repository's [license](LICENSE).

---

## Как помочь проекту

Самое полезное — хорошие сообщения об ошибках из настоящих кооп-сессий, затем небольшие проверенные исправления.

**Сообщить об ошибке:**
1. Проверьте, что у всех игроков одна версия SDCoop. Она видна в панели «Кооператив» и в `UE4SS.log` в строке `[SNAP] head v=…`.
2. Откройте **Issues → New issue → Bug report**. Кнопка «Сообщить об ошибке» в панели открывает эту форму с уже заполненной версией.
3. Приложите `UE4SS.log` **и хоста, и клиента**: `SurrounDead\Binaries\Win64\ue4ss\UE4SS.log`. Лог хоста перезаписывается при перезапуске игры, поэтому скопируйте его сразу после игры.
4. Уберите из логов Steam ID и другие личные данные.

**Изменения в коде:** сначала прочитайте [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), правила там выведены из настоящих вылетов. Делайте небольшие изменения. Комментарии и лог пишите по-английски, текст на экране — через `sdc_i18n.lua` на двух языках. К исправлению ошибки добавьте тест `tests/mock_<тема>.lua`, который падает на старом коде.

**Pull request:** опишите, что было сломано, как исправлено и как проверено, и изменился ли формат сетевых сообщений.
