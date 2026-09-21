# Lampa Desktop

Готовая Windows-сборка медиакаталога [Lampa](https://github.com/yumata/lampa): обычное окно приложения, без браузера, без локального веб-сервера.

[![Загрузки](https://img.shields.io/github/downloads/XEGARE/Lampa-Desktop/total?label=%D0%97%D0%B0%D0%B3%D1%80%D1%83%D0%B7%D0%BA%D0%B8&logo=github&style=for-the-badge)](https://github.com/XEGARE/Lampa-Desktop/releases)
[![Скачивания последнего релиза](https://img.shields.io/github/downloads/XEGARE/Lampa-Desktop/latest/total?label=%D0%9F%D0%BE%D1%81%D0%BB%D0%B5%D0%B4%D0%BD%D0%B8%D0%B9%20%D1%80%D0%B5%D0%BB%D0%B8%D0%B7&style=for-the-badge)](https://github.com/XEGARE/Lampa-Desktop/releases/latest)
[![Последний релиз](https://img.shields.io/github/v/release/XEGARE/Lampa-Desktop?label=%D0%A0%D0%B5%D0%BB%D0%B8%D0%B7&style=for-the-badge)](https://github.com/XEGARE/Lampa-Desktop/releases/latest)
[![Сборка](https://img.shields.io/github/actions/workflow/status/XEGARE/Lampa-Desktop/release.yml?label=%D0%A1%D0%B1%D0%BE%D1%80%D0%BA%D0%B0&style=for-the-badge)](https://github.com/XEGARE/Lampa-Desktop/actions)

## Что это

Lampa — бесплатный каталог фильмов и сериалов. Он показывает публичную информацию о новинках и популярных тайтлах и не раздаёт видео со своих серверов.

Этот проект упаковывает Lampa в десктопную оболочку для Windows x64:

- своя рамка окна (свернуть / развернуть / закрыть);
- можно указать свой адрес Lampa, если вы поднимаете её отдельно;
- по умолчанию открывается встроенная копия Lampa из сборки.

Скачайте архив из [Releases](https://github.com/XEGARE/Lampa-Desktop/releases/latest), распакуйте и запустите `Lampa.exe`. Профиль Chromium хранится в папке `user` рядом с программой.

## Что используется

| Компонент | Зачем |
| --- | --- |
| [Lampa](https://github.com/yumata/lampa) | Сам каталог (исходники: [lampa-source](https://github.com/yumata/lampa-source)) |
| [NW.js](https://nwjs.io) | Окно приложения на Chromium + Node.js |
| [nwjs-ffmpeg-prebuilt](https://github.com/nwjs-ffmpeg-prebuilt/nwjs-ffmpeg-prebuilt) | Кодеки для воспроизведения в Chromium |
| [Resource Hacker](https://www.angusj.com/resourcehacker/) | Иконки, свойства и версии `Lampa.exe` / `nw.dll` |
| [GitHub Actions](https://github.com/features/actions) | Сборка, проверка обновлений и публикация релизов |
| PowerShell | Скрипт сборки `scripts/Build-Release.ps1` |

Готовый архив в релизе — это NW.js, FFmpeg, Lampa и файлы из каталога `app/` (рамка окна, `package.json`, иконка).

## Автоматические релизы

Workflow `.github/workflows/release.yml` собирает приложение на Windows и публикует zip в GitHub Releases.

Сборка запускается:

1. **При коммитах в этот репозиторий** (ветка `main` / `master`) — изменилась оболочка, скрипт сборки или workflow.
2. **Раз в сутки** (04:00 UTC) — скрипт сверяет стабильную версию NW.js и последний коммит `yumata/lampa` с предыдущим релизом. Если ничего не изменилось, новая сборка не создаётся.
3. **Вручную** в Actions (`workflow_dispatch`), при необходимости с принудительной пересборкой.

В описании релиза пишется всё, что реально изменилось:

- переход NW.js (включая Chromium и Node.js) и ссылка на [блог NW.js](https://nwjs.io/blog/);
- обновление FFmpeg prebuilt под ту же версию NW.js;
- коммиты Lampa со ссылками и compare;
- коммиты этой оболочки со ссылками и compare.

К релизу прикладываются `Lampa-Desktop-win-x64.zip` и `build-info.json` (версии и SHA для следующей сверки).

## Сборка у себя

Нужны Windows x64 и PowerShell 5.1+ (на GitHub Actions используется PowerShell 7). Дальше:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1 -SkipRelease
```

или `Build.cmd`. Архив появится в `out\Lampa-Desktop-win-x64.zip`.
