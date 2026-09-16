# frozen_string_literal: true

# Notifikácia o reakcii bola naviazaná na KONKRÉTNU reakciu (`source_type = 'Reaction'`).
# To je chyba, lebo Redmine pri odlajkovaní riadok v `reactions` ZMAŽE a pri opätovnom
# lajku vytvorí nový s iným id. Tridsať prepnutí teda vyrobilo tridsať notifikácií,
# z ktorých dvadsaťdeväť ukazovalo na neexistujúcu reakciu — a odznak ich počítal, kým
# ich otvorenie panelu nezahodilo. Odtiaľ „34 na zvončeku, 2 v zozname".
#
# Riešenie: kľúčom je dvojica (objekt, kto lajkol). Tá prepínanie prežije.
#   * `actor_id`     — kto akciu spravil; pri reakciách ten, kto dal 👍. Pri ostatných
#                      udalostiach 0, lebo tam je pôvodca odvoditeľný zo zdroja.
#   * `retracted_on` — kedy bola akcia vzatá späť. Riadok sa NEMAŽE, len prestane platiť:
#                      vďaka tomu vieme pri opätovnom lajku do 30 minút použiť ten istý
#                      záznam namiesto toho, aby vznikla druhá notifikácia o tom istom.
class RekeyReactionNotifications < ActiveRecord::Migration[7.2]
  def up
    add_column :inapp_notifications, :actor_id, :integer, :null => false, :default => 0
    add_column :inapp_notifications, :retracted_on, :datetime

    rekey_existing_reaction_rows

    # Unique index musí po `actor_id` siahnuť tiež, inak by dvaja ľudia, ktorí lajkli
    # ten istý komentár, spadli do jedného riadku. `actor_id` má default 0 (nie NULL)
    # zámerne — Postgres považuje NULL-y v unique indexe za navzájom RÔZNE, takže by
    # index prestal dedupovať všetko ostatné.
    remove_index :inapp_notifications, :name => 'index_inapp_notifications_dedup'
    add_index :inapp_notifications, %i[user_id event source_type source_id actor_id],
              :unique => true, :name => 'index_inapp_notifications_dedup'

    # Odznak nesmie počítať stiahnuté riadky — to je presne tá chyba, ktorú to opravuje.
    remove_index :inapp_notifications, :name => 'index_inapp_notifications_unread'
    add_index :inapp_notifications, :user_id,
              :where => 'read_on IS NULL AND retracted_on IS NULL',
              :name  => 'index_inapp_notifications_unread'
  end

  def down
    remove_index :inapp_notifications, :name => 'index_inapp_notifications_dedup'
    remove_index :inapp_notifications, :name => 'index_inapp_notifications_unread'

    # Riadky o reakciách sa späť na id reakcie preložiť nedajú (pôvodné reakcie už
    # neexistujú), takže sa zahodia. Je to notifikačná história, nie dáta Redmine.
    execute "DELETE FROM inapp_notifications WHERE event = 'reaction_added'"

    remove_column :inapp_notifications, :retracted_on
    remove_column :inapp_notifications, :actor_id

    add_index :inapp_notifications, %i[user_id event source_type source_id],
              :unique => true, :name => 'index_inapp_notifications_dedup'
    add_index :inapp_notifications, :user_id, :where => 'read_on IS NULL',
              :name => 'index_inapp_notifications_unread'
  end

  private

  # Existujúce riadky sa prepíšu na nový kľúč. Čo sa preložiť nedá (reakcia medzitým
  # zanikla) alebo by po prepise kolidovalo s iným riadkom, sa zmaže — je to práve ten
  # duplicitný šum, kvôli ktorému sa to celé prerába.
  def rekey_existing_reaction_rows
    say_with_time 'prepis notifikacii o reakciach na (objekt, autor lajku)' do
      # `.to_a` je nutne: `select_all` vracia ActiveRecord::Result, ktory `size` nema.
      rows = select_all(<<~SQL.squish).to_a
        SELECT id, user_id, source_id FROM inapp_notifications
        WHERE event = 'reaction_added' AND source_type = 'Reaction' ORDER BY id
      SQL

      seen    = {}
      deleted = 0

      rows.each do |row|
        reaction = select_one(
          "SELECT reactable_type, reactable_id, user_id FROM reactions WHERE id = #{row['source_id'].to_i}"
        )

        key = reaction && [row['user_id'], reaction['reactable_type'],
                           reaction['reactable_id'], reaction['user_id']]

        if reaction.nil? || seen[key]
          execute "DELETE FROM inapp_notifications WHERE id = #{row['id'].to_i}"
          deleted += 1
          next
        end

        seen[key] = true
        execute(<<~SQL.squish)
          UPDATE inapp_notifications
             SET source_type = #{quote(reaction['reactable_type'])},
                 source_id   = #{reaction['reactable_id'].to_i},
                 actor_id    = #{reaction['user_id'].to_i}
           WHERE id = #{row['id'].to_i}
        SQL
      end

      say "prepisanych #{rows.size - deleted}, zmazanych mrtvych/duplicitnych #{deleted}", true
      rows.size
    end
  end
end
