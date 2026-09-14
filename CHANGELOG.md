# Changelog

## 0.1.0 - 2026-09-14

Prvá verzia — zber notifikácií, panel pri zvončeku a plná stránka.

- **Záchyt na `Mailer`, nie na modeloch.** `Mailer#process` garantuje tvar `(príjemca, objekt)`,
  takže sa dvojica *komu / o čom* dá odčítať bez toho, aby si plugin počítal adresátov sám.
  Vďaka tomu fungujú **bez jediného zásahu** aj `redmine_notify_field_users`,
  `redmine_notification_filter`, `redmine_notify_reactions` a `redmine_remind_me` — pričom prvé
  dva aktívne menia, komu mail ide.
- Rozhodnutie „zapísať / nezapísať" padá až v `Mailer#mail` po `super`, lebo `no_self_notified`
  sa v jadre aplikuje až tam. Inak by autor dostal notifikáciu o vlastnej zmene, hoci mu mail
  zámerne neprišiel.
- **Ukladá sa odkaz, nie text** — vykresľuje sa za behu z `acts_as_event`. Notifikácia tak
  nemôže prezradiť názov úlohy, na ktorú človek stratil právo.
- Viditeľnosť sa kontroluje dávkovo, pre úlohy a komentáre cez scope `Journal.visible(user)`.
  `Journal#visible?` sa **nepoužíva** — nerieši súkromné poznámky.
- Zmazané zdroje sa pri čítaní ticho zahodia a rovno zmažú (tabuľka sa lieči sama); neznámy
  `source_type` po odinštalovanom plugine loader prežije, lebo sa prekladá cez whitelist tried
  a nie cez `constantize`.
- Retencia bez cronu — mazanie beží v bežnom requeste a len keď je čo mazať.
- Zvonček pribudol do hlavičky **naľavo od prútika AI**; filter e-mailových notifikácií, ktorý
  zvonček dovtedy zaberal, dostal vlastnú ikonu (obálka s ozubeným koliečkom) vo všetkých troch
  témach. Zvonček tak konečne otvára notifikácie a nie ich nastavenia.

Dve veci, ktoré sa počas vývoja ukázali ako reálne chyby a sú ošetrené:

- **Unique violation v Postgrese zabíja celú transakciu**, aj keď sa výnimka odchytí v Ruby.
  Zápis preto beží vo vnorenej transakcii (SAVEPOINT) — inak by jedna duplicitná notifikácia
  strhla so sebou celé uloženie, keď sa mail posiela synchrónne.
- **N+1, ktorý `preload` nechytí:** `Journal#event_title` aj `event_type` volajú
  `IssueStatus.find_by_id` na každý riadok (+28 dotazov pri 40 riadkoch) a nepomôže ani query
  cache, lebo každý stav má iné id. Nadpis aj typ sa preto skladajú z mapy načítanej raz.
  Výsledok: 13 dotazov na 20 aj na 50 riadkov.

Selftest: 30 kontrol. Migrácia: jedna tabuľka, partial index na neprečítané.
