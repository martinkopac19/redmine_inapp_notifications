# frozen_string_literal: true

module InappNotifications
  # Načítanie zoznamu notifikácií pre jedného človeka.
  #
  # Toto je jediné miesto, ktoré sa dotýka zdrojových objektov, a robí naraz tri veci, ktoré
  # spolu súvisia viac, než sa zdá:
  #   1. dávkovo načíta objekty (inak by 20 riadkov znamenalo stovky dotazov),
  #   2. zahodí tie, ktoré medzitým zmizli (a rovno ich zmaže z tabuľky),
  #   3. zahodí tie, ktoré daný človek už nesmie vidieť.
  #
  # Body 2 a 3 sa navzájom podobajú, ale majú OPAČNÝ dôsledok: zmazaný objekt je nenávratný,
  # takže riadok mažeme; stratené právo sa môže vrátiť (dočasne odobratá rola), takže riadok
  # necháme a len ho nevykreslíme.
  class Loader
    Row = Struct.new(:notification, :source, keyword_init: true)

    def initialize(user)
      @user = user
    end

    # Vracia pole `Row` — notifikácia + jej živý, viditeľný zdroj.
    def list(limit: InappNotifications.panel_limit, offset: 0)
      rows = InappNotification.for_user(@user).active.recent.limit(limit).offset(offset).to_a
      return [] if rows.empty?

      loaded = load_objects(rows)
      drop_dead(rows, loaded)

      rows.filter_map do |n|
        source = loaded.dig(n.source_type, :visible)&.[](n.source_id)
        next if source.nil?

        Row.new(:notification => n, :source => source)
      end
    end

    # Mapa `id => IssueStatus` pre presenter. Načíta sa RAZ a len keď je v zozname aspoň
    # jeden Journal — bez nej robí `Journal#event_title` jeden dotaz na každý riadok
    # (zmerané: 28 dotazov navyše pri 40 journaloch). Tabuľka má rádovo desiatky riadkov,
    # takže sa načíta celá; filtrovať podľa použitých id by bol ďalší dotaz zadarmo.
    def statuses_for(rows)
      return {} unless rows.any? { |r| r.notification.source_type == 'Journal' }

      @statuses ||= IssueStatus.all.index_by(&:id)
    end

    # Mapa `id => User` pre riadky o reakciách — kto dal 👍. Zdrojom takého riadku je
    # objekt, NA KTORÝ sa reagovalo (aby prepínanie lajku nevyrábalo ďalšie a ďalšie
    # notifikácie), takže autora z neho vyčítať nejde. Jeden dotaz na celý zoznam.
    def actors_for(rows)
      ids = rows.filter_map { |r| r.notification.actor_id if r.notification.event == Events::REACTION }
                .uniq.reject(&:zero?)
      return {} if ids.empty?

      User.where(:id => ids).index_by(&:id)
    end

    # Autoritatívny počet neprečítaných — teda po odfiltrovaní toho, čo človek nesmie vidieť.
    # Odznak v hlavičke počíta surovo (viď `InappNotification.unread_count_for`); týmto číslom
    # ho panel po otvorení prepíše, takže sa prípadný rozdiel sám opraví.
    #
    # Strop je tu naschvál: keď má niekto 800 neprečítaných, nemá zmysel kvôli presnému číslu
    # načítavať 800 objektov. Nad strop sa ukáže „99+" a to je aj tak všetko, čo sa do odznaku
    # zmestí.
    def unread_count(cap: 100)
      rows = InappNotification.for_user(@user).unread.active.recent.limit(cap).to_a
      return 0 if rows.empty?

      loaded = load_objects(rows)
      rows.count { |n| loaded.dig(n.source_type, :visible)&.[](n.source_id) }
    end

    private

    # Jeden dotaz na TYP, nie na riadok. Pri 20 riadkoch sú reálne 1-3 rôzne typy,
    # takže celkovo 4-8 dotazov — a čo je dôležitejšie, ten počet nerastie s dĺžkou zoznamu.
    #
    # Vracia pre každý typ DVE veci:
    #   :alive   — id, ktoré v databáze existujú (pred kontrolou práv),
    #   :visible — objekty, ktoré sa smú ukázať.
    # Rozlíšenie je nutné, lebo `drop_dead` smie mazať len naozaj zmazané objekty. Keby
    # dostal len viditeľné, dočasne odobratá rola by človeku trvalo zmazala notifikácie.
    def load_objects(rows)
      out = {}

      rows.group_by(&:source_type).each do |type, group|
        klass = Events.klass_for(type)
        # Neznámy typ = riadok po odinštalovanom plugine. `drop_dead` ho zmaže.
        # Bez tejto vetvy by `constantize` zhodil hlavičku každej stránky.
        next if klass.nil?

        found = fetch(klass, type, group.map(&:source_id).uniq)
        out[type] = {
          :alive   => found.map(&:id).to_set,
          :visible => visible_only(klass, type, found).index_by(&:id)
        }
      end

      out
    end

    def fetch(klass, type, ids)
      klass.where(:id => ids).preload(*Events.preloads_for(type)).to_a
    rescue StandardError => e
      # Napr. keď plugin zmizol aj s tabuľkou. Radšej prázdny zoznam než rozbitá hlavička.
      Rails.logger&.warn("[inapp_notifications] #{type} sa nedal nacitat: #{e.class}")
      []
    end

    # Kontrola viditeľnosti — dávkovo, nikdy `visible?` riadok po riadku.
    #
    # Pre Issue a Journal (spolu >95 % objemu) sa použije SCOPE, nie inštančná metóda.
    # Je to zásadný rozdiel: `Journal#visible?` (journal.rb:165) deleguje len na
    # `journalized.visible?` a o SÚKROMNÝCH POZNÁMKACH nevie nič — človek bez práva
    # `view_private_notes` by v paneli videl názov aj úryvok súkromnej poznámky.
    # `Journal.visible(user)` (journal.rb:68-75) pridáva `visible_notes_condition`
    # a rieši to správne. Preto scope.
    def visible_only(klass, type, objects)
      return objects if objects.empty?

      if klass.respond_to?(:visible) && %w[Issue Journal].include?(type)
        allowed = klass.visible(@user).where(:id => objects.map(&:id)).pluck(:id).to_set
        return objects.select { |o| allowed.include?(o.id) }
      end

      # Ostatné typy: `visible?` je u nich len `user.allowed_to?(:view_x, project)`, a keďže
      # projekty sú preloadnuté a role sa v `User` memoizujú, stojí to 0 dotazov navyše.
      objects.select { |o| safe_visible?(o) }
    end

    def safe_visible?(object)
      return true unless object.respond_to?(:visible?)

      object.visible?(@user)
    rescue StandardError
      # Keď sa viditeľnosť nedá vyhodnotiť, radšej NEUKÁZAŤ.
      false
    end

    # Riadky, ktorých zdroj v databáze už neexistuje, sa rovno zmažú — tabuľka sa tým
    # sama lieči a purge má menej práce. Žiadny dotaz navyše: pracuje sa s `:alive`,
    # ktoré už `load_objects` zistilo.
    #
    # POZOR na rozdiel oproti viditeľnosti: mažú sa len NAOZAJ ZMAZANÉ objekty, nie tie,
    # na ktoré človek stratil právo — právo sa môže vrátiť, zmazaná úloha nie.
    def drop_dead(rows, loaded)
      dead = rows.reject { |n| loaded.dig(n.source_type, :alive)&.include?(n.source_id) }
                 .map(&:id)
      InappNotification.where(:id => dead).delete_all if dead.any?
    end
  end
end
