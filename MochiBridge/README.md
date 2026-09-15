# Mochi Bridge — iPhone

Это заготовка iOS-приложения для прямого подключения The Mochi по BLE без Chronos.

## BLE
- Service: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- RX/write: `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- TX/notify: `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`

Приложение автоматически ищет устройство, подключается, подписывается на notifications и отправляет заряд iPhone и время.

## Реализовано
- BLE connection
- iPhone battery -> Mochi
- time -> Mochi
- Chronos notification packet test
- incoming-call/end-call indication where iOS exposes call state
- Play/Pause/Next/Previous controls through iOS system music player
- BLE HEX log

## Ограничения iOS
iOS не предоставляет обычному стороннему приложению универсальный доступ к уведомлениям всех других приложений или к названию/исполнителю текущего трека другого приложения. Поэтому Android-версию Chronos нельзя 1:1 перенести на iOS через публичные API.

## Установка на Windows
Нужна сборка на macOS/Xcode или macOS CI, после чего IPA можно подписать и установить на iPhone через Sideloadly/AltStore-подобный способ. Исходник намеренно не требует Chronos.
