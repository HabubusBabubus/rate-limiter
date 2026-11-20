# Rate Limiter

**Slow down any machine by a percentage — output, input, power and pollution together.**

Type 50 and the machine works at half speed — or type the output you want, like 0.7 ore per second, and the mod works out the percentage: half the products, half the ingredients, half the fuel or electricity, half the pollution. 25 — four times slower. 0 — stopped. Any number of decimals.

---

## Features

- **Every producing machine:** assemblers, furnaces, chemical plants, refineries, centrifuges, mining drills, pumpjacks, labs, rocket silo, boilers, heat exchangers, steam engines and turbines, nuclear reactors, solar panels, offshore pumps.
- **Space Age** (optional): foundry, electromagnetic plant, cryogenic plant, biochamber, recycler, agricultural tower, captive spawner, asteroid collector, fusion reactor and generator, heating tower.
- **Panel next to the machine window:** slider, number field, presets 100 / 75 / 50 / 25 / 0%. Works for ghosts too.
- **Limit by output:** pick a product (any of them for multi-product machines like oil refineries) and the amount per second or minute; recalculated automatically when modules, beacons, recipe or ore yield change.
- **Reference block:** output, input, fuel, electricity and emissions of the machine at the current limit.
- **Selection tool** (shortcut bar or Ctrl+Alt+R): set the limit for a whole area at once; Shift + drag resets to 100%.
- **Circuit network:** pick a signal, its value becomes the percentage.
- **Alt mode:** the limit is shown over the machine.
- **Kept everywhere:** blueprints, copy/cut, Shift+RMB / Shift+LMB settings paste, rebuilt ghosts after destruction, undo, fast-replace, upgrade planner.

## How it works

Machines that accept modules are slowed smoothly with script effects (Factorio 2.1.13+). Your own modules and beacons keep working: 50% is always half of the machine's real speed. Productivity is not changed.

The game does not allow speed or power below 20%, so deeper limits add pulses: the machine is switched on for part of each cycle. Boilers, generators, reactors, pumps and other machines without modules always work in pulses. The average is exact; the cycle length is a map setting.

## Commands

- `/rl-reset-all` — give every machine back its full speed (admins). Run it before removing the mod.
- `/rl-info` — state of the machine under the cursor.

---

# Rate Limiter (RU)

**Замедляет любую машину на заданный процент — выпуск, потребление, энергию и загрязнение вместе.**

Введите 50 — машина работает вдвое медленнее (или укажите нужный выпуск, например 0,7 руды в секунду, и мод сам посчитает процент): вдвое меньше продукции, сырья, топлива или электричества и загрязнения. 25 — в четыре раза медленнее. 0 — остановка. Любое число знаков после запятой.

## Возможности

- **Все производящие машины:** сборочные автоматы, печи, химзаводы, НПЗ, центрифуги, буры, насосные качалки, лаборатории, ракетная шахта, котлы, теплообменники, паровые двигатели и турбины, ядерные реакторы, солнечные панели, водяные насосы.
- **Space Age** (необязательно): литейная, электромагнитный завод, криозавод, биокамера, переработчик, агробашня, плененный спавнер, сборщик астероидов, термоядерные реактор и генератор, нагревательная башня.
- **Панель рядом с окном машины:** ползунок, поле для числа, кнопки 100 / 75 / 50 / 25 / 0%. Работает и для призраков.
- **Ограничение по выпуску:** выберите продукт (у машин с несколькими продуктами, например НПЗ, — любой) и количество в секунду или минуту; пересчитывается автоматически при смене модулей, маяков, рецепта или богатства руды.
- **Справка:** выпуск, потребление, топливо, электроэнергия и выбросы машины при текущем ограничении.
- **Инструмент выделения** (панель быстрого доступа или Ctrl+Alt+R): задать ограничение целой области; выделение с Shift возвращает 100%.
- **Логическая сеть:** выберите сигнал, его значение станет процентом.
- **Alt-режим:** ограничение видно над машиной.
- **Сохраняется везде:** чертежи, копирование и вырезание, копирование настроек Shift+ПКМ / Shift+ЛКМ, призраки после разрушения, отмена, быстрая замена, планировщик улучшений.

## Как это работает

Машины с модулями замедляются плавно скриптовыми эффектами (Factorio 2.1.13+). Ваши модули и маяки продолжают работать: 50% — это всегда половина реальной скорости машины. Продуктивность не меняется.

Игра не позволяет опустить скорость или энергию ниже 20%, поэтому для более глубокого замедления добавляются импульсы: машина включена часть каждого цикла. Котлы, генераторы, реакторы, насосы и другие машины без модулей всегда работают импульсами. Среднее значение точное; длина цикла — настройка карты.

## Команды

- `/rl-reset-all` — вернуть всем машинам полную скорость (админы). Выполните перед удалением мода.
- `/rl-info` — состояние машины под курсором.
