# frozen_string_literal: true

# Jedna tabuľka, sedem stĺpcov, ŽIADNY TEXT.
#
# Text notifikácie sa zámerne neukladá — vykresľuje sa za behu z objektu cez natívne
# `acts_as_event` (`event_title`, `event_author`, `event_url`…). Dôvod nie je úspora miesta,
# ale bezpečnosť: keď človek stratí právo na úlohu, nemá v paneli zostať svietiť jej názov.
# Keby sme si text odložili, museli by sme ho pri každej zmene práv niekde dohľadávať a mazať.
#
# Stĺpce sa menujú `created_on` (nie rails-ovské `created_at`) kvôli konvencii Redmine.
class CreateInappNotifications < ActiveRecord::Migration[7.2]
  def change
    create_table :inapp_notifications do |t|
      t.references :user, null: false
      # `event` = názov akcie mailera ('issue_add', 'issue_edit', 'reaction_added'…).
      # Podľa neho sa vyberá ikona a formulácia riadku.
      t.string  :event,       null: false, limit: 32
      # Polymorfný odkaz na zdroj. `source_type` sa NIKDY nedáva do `constantize` —
      # prekladá sa cez pevný whitelist tried v `InappNotifications::Events`.
      t.string  :source_type, null: false, limit: 32
      t.integer :source_id,   null: false
      # Jediná denormalizácia, a nie je na vykresľovanie: keď človeka vyhodia z projektu,
      # vieme jeho čakajúce notifikácie zmazať jedným DELETE bez toho, aby sme sa museli
      # pýtať každého objektu zvlášť, či ho ešte smie vidieť.
      t.integer :project_id
      # KEDY SME NOTIFIKOVALI — nie `event_datetime` objektu. Pri hromadnej úprave alebo
      # oneskorenom doručení sa tie dva časy rozchádzajú a v paneli chceme ten náš.
      t.datetime :created_on, null: false
      # NULL = neprečítané. Bez druhého stĺpca „videné" — otvorenie panelu nič neoznačuje,
      # rovnako ako to robí Facebook.
      t.datetime :read_on
    end

    # Zoznam v paneli: WHERE user_id = ? ORDER BY id DESC LIMIT 20.
    add_index :inapp_notifications, %i[user_id id]

    # Počet pri zvončeku sa počíta na KAŽDOM renderi KAŽDEJ stránky — toto je jediný index,
    # na ktorom naozaj záleží. Partial index drží v strome len neprečítané, čo je zlomok
    # tabuľky (prečítané sa navyše po 30 dňoch mažú).
    # Postgres-only, a tento stack je Postgres-only (klon aj server).
    add_index :inapp_notifications, :user_id,
              where: 'read_on IS NULL', name: 'index_inapp_notifications_unread'

    # Idempotencia. Zápis beží v ActiveJob-e (`deliver_later`), ktorý sa pri chybe opakuje —
    # bez tohto indexu by opakovaný beh vyrobil druhý riadok o tej istej udalosti.
    add_index :inapp_notifications, %i[user_id event source_type source_id],
              unique: true, name: 'index_inapp_notifications_dedup'

    # Upratovanie starých záznamov.
    add_index :inapp_notifications, :created_on

    # Zdroj je polymorfný, takže naň FK spraviť nejde — mŕtve riadky rieši loader a purge.
    # Na užívateľa ale FK ide, a pokrýva najčastejšie reálne mazanie zadarmo.
    add_foreign_key :inapp_notifications, :users, on_delete: :cascade
  end
end
