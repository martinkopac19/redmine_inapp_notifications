# Changelog

## 0.2.0 - 2026-09-16

**Oprava: prepínanie lajku vyrábalo notifikáciu za notifikáciou.** Kto dal a odobral 👍
tridsaťkrát, poslal adresátovi tridsať notifikácií — a odznak ukazoval 34, kým panel
zobrazil dve. Boli to dve chyby naraz:

- Notifikácia bola naviazaná na **konkrétnu reakciu**. Redmine pri odlajkovaní riadok
  v `reactions` zmaže a pri opätovnom lajku vytvorí nový s iným id, takže unique index
  nemal čo dedupovať. Kľúčom je teraz **dvojica (objekt, kto lajkol)**, ktorá prepínanie
  prežije — pribudol stĺpec `actor_id` a je súčasťou unique indexu.
- Odobratie lajku notifikáciu **nezahodilo hneď**. Riadok zostal visieť a odznak ho
  počítal, lebo je to surový COUNT, ktorý sa k zdrojovým objektom nepozerá; zahodilo ho
  až otvorenie panelu. Teraz sa pri odobratí označí ako stiahnutý (`retracted_on`)
  a z odznaku aj zo zoznamu zmizne okamžite.

Riadok sa pri odobratí **nemaže**, len prestane platiť. Vďaka tomu vie opätovný lajk
**do 30 minút** použiť ten istý záznam a nevyrobiť druhú notifikáciu o tom istom — a keď
ho človek už čítal, odznak mu druhýkrát nenaskočí. Po uplynutí okna je to nová udalosť.
Dĺžka okna je nastaviteľná (*Administration → Plugins*), predvolene 30 minút, rovnako ako
okno na zlučovanie úprav popisu v `redmine_rich_editor`.

Migrácia existujúce riadky prepíše na nový kľúč; mŕtve a duplicitné zahodí.

**Pozor — e-mailov sa to netýka.** Tie posiela `redmine_notify_reactions` a ten stále
pošle jeden mail za každý lajk. Toto zlučovanie platí len pre zvonček.

## 0.1.1 - 2026-09-15

- **Oprava: „Označiť všetko" na plnej stránke skončilo na holom JSON-e.** Odkaz tam nie je
  volanie na pozadí ako v paneli, ale obyčajný POST cez rails-ujs — kontrolér ale vracal JSON
  vždy, takže prehliadač zobrazil `{"unread": 0}` namiesto zoznamu. Označenie sa pritom
  korektne vykonalo; navonok to vyzeralo ako chyba. `read_all` teraz odpovedá podľa volajúceho:
  JSON pre `fetch` z panelu, presmerovanie späť na zoznam pre bežný request.

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
