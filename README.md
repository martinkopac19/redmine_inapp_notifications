# Redmine In-app notifications (Previo)

Zvonček v hlavičke s počtom neprečítaných a panelom so zoznamom — to, čo dnes chodí len
mailom, je vidieť aj priamo v Redmine.

**Maily bežia ďalej nezmenené.** In-app je druhý kanál, nie náhrada: notifikáciu dostane
presne ten, komu by prišiel mail.

## Ako to funguje

Redmine 6.1 nemá žiadnu in-app notifikačnú vrstvu — v databáze nie je nič, čo by sledovalo,
o čom sa komu dalo vedieť a čo už videl. Notifikácie vznikajú roztrúsene, cez
`after_create_commit` callbacky na jednotlivých modeloch, a každý volá priamo `Mailer`.

Plugin sa preto **nabaľuje na `Mailer`, nie na modely**. Jadro síce nemá centrálne miesto pre
udalosti, ale má ho pre maily: `Mailer#process` vynucuje, že prvý argument každej mailovej
akcie je príjemca. Odtiaľ sa dá bez ďalšej logiky odčítať dvojica *(komu, o čom)*.

Nie je to pohodlnosť. V tejto inštancii **tri ďalšie pluginy aktívne menia, komu mail ide**:

| Plugin | Čo robí s adresátmi |
|---|---|
| `redmine_notify_field_users` | pridáva ľudí z polí Tester / PM / Code review |
| `redmine_notification_filter` | odfiltruje ich podľa prechodu stavu |
| `redmine_notify_reactions` | pridáva vlastný mail o lajku |
| `redmine_remind_me` | pridáva vlastný mail o pripomienke |

Keby si plugin počítal príjemcov sám, in-app by sa s mailmi rozišlo. Takto sú z definície
rovnaké a **v žiadnom z tých štyroch pluginov sa nemenil ani riadok**.

Zachytávajú sa len akcie z whitelistu (`lib/inapp_notifications/events.rb`). Neznáma akcia sa
ticho preskočí, takže účtové a bezpečnostné maily (`lost_password`, `security_notification`,
`test_email`…) sa do zvončeka nedostanú — a ani sa nemuseli menovať.

## Čo sa ukladá

Riadok nesie **len odkaz** na zdroj: príjemca, typ, id, projekt, čas a stav prečítania.
Text sa vykresľuje za behu z natívneho `acts_as_event` daného objektu. Dôvod je bezpečnostný:
keď človek stratí právo na úlohu, nemá v paneli zostať svietiť jej názov — a keby sme si text
odložili, museli by sme ho pri každej zmene práv niekde dohľadávať.

Pri každom čítaní sa preto kontroluje viditeľnosť. Pre úlohy a komentáre cez **scope**
`Journal.visible(user)`, nie cez `Journal#visible?` — inštančná metóda o súkromných poznámkach
nevie a bola by to diera.

## Nastavenia

*Administration → Plugins → In-app notifications*: kill-switch, počet riadkov v paneli
a retencia (predvolene 30 dní pre prečítané, 180 pre všetko). Staré záznamy sa mažú počas
bežného requestu — **žiadny cron netreba**, a spustí sa to len keď je naozaj čo mazať.

## Testy

```sh
# Ruby — 30 kontrol, celé v transakcii s rollbackom, maily do :test adaptéra
bin/rails runner -e production plugins/redmine_inapp_notifications/extra/selftest.rb

# UI — headless Edge cez CDP
node extra/ui_cdp_test.mjs <base> <login> <heslo> [port]
```

Najdôležitejšia kontrola je **N+1**: počet SQL dotazov nesmie rásť s dĺžkou zoznamu.
Aktuálne 13 dotazov na 20 aj na 50 riadkov. Dve miesta to porušovali — `Journal#event_title`
aj `event_type` volajú `IssueStatus.find_by_id` na každý riadok (namerané +28 dotazov pri 40
riadkoch). Obe sa preto v `Presenter`-i skladajú z predpočítanej mapy stavov.

## Známe obmedzenia

- Kto má v *Môj účet* vypnuté všetky e-mailové notifikácie, nedostane ani in-app — in-app je
  od mailu odvodené. Na 114 účtoch sa to týka piatich ľudí.
- Zmeny sa nezlučujú: každá je vlastný riadok, verne ako mail. Pri najaktívnejších ľuďoch to
  môže byť ~70 riadkov denne.
- Panel sa neobnovuje sám — počet sa aktualizuje pri prechode na ďalšiu stránku.

## Licencia

Copyright (C) 2026 Martin Kopáč

GPL-2.0-or-later, rovnako ako Redmine — viď [LICENSE](LICENSE).
