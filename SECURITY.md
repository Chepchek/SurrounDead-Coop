# Security policy

**English** · [Русский](#безопасность)

## Supported versions
Only the latest release on the [Releases page](../../releases/latest) gets fixes. Every player in a session must run the same version anyway.

## What counts as a security problem
SDCoop runs Lua inside the game through UE4SS and ships a small Steam helper (`SDCoopSteamLink.exe`, source in `tools/steamlink`). Please report privately:
- a way for another player to crash a host or a client, or run code on their PC, through network messages;
- a way to get past the host's kick or ban;
- the Steam helper accepting connections it should refuse (non-friends, banned players);
- anything that leaks personal data (Steam IDs, Windows user names, file paths) to other players or into files meant for sharing;
- a release archive that contains something it should not.

Gameplay cheating by a player with a modified copy of the mod is a known limit, not a vulnerability. The host's own world is the source of truth, but a client can still lie about its own movement and progress.

## How to report
- Use **Security → Report a vulnerability** on this repository if it is available.
- If it is not, open an issue titled "Security" **without** details and ask for a private channel.

Include the SDCoop version, steps to reproduce and the logs, with personal data removed.

You will get an answer within a few days. Please give us a reasonable time to release a fix before you publish details.

## Downloads
Get SDCoop only from this repository's Releases page. Other "multiplayer mods" for this game have been reported as malware.

---

## Безопасность

Исправления выходят только для последней версии на странице Releases.

**Сообщайте приватно:**
- как другой игрок может уронить игру хоста или клиента или выполнить код на чужом ПК через сетевые сообщения;
- как обойти кик или бан;
- помощник Steam пускает тех, кого не должен;
- утечки личных данных: Steam ID, имена пользователей Windows, пути к файлам;
- в архив релиза попало лишнее.

Читерство игрока с изменённым модом — известное ограничение, а не уязвимость.

**Как сообщить:** вкладка **Security → Report a vulnerability**, если она доступна. Иначе откройте issue «Security» без подробностей и попросите приватный канал.

Скачивайте SDCoop только со страницы Releases этого репозитория.
