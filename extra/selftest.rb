# frozen_string_literal: true

# Selftest pluginu redmine_inapp_notifications.
#
#   bin/rails runner -e production plugins/redmine_inapp_notifications/extra/selftest.rb
#
# Celé beží vo VONKAJŠEJ TRANSAKCII s rollbackom — na klóne aj na serveri sú reálne
# produkčné dáta a test po sebe nesmie nechať ani riadok. Maily idú do `:test` adaptéra,
# takže nikam neodídu.
def ok(bool)
  bool ? 'OK' : '!! CHYBA'
end

def count_sql
  n = 0
  sub = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
    n += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/
  end
  yield
  ActiveSupport::Notifications.unsubscribe(sub)
  n
end

puts '=' * 78
puts '  redmine_inapp_notifications selftest'
puts '=' * 78

orig_delivery = ActionMailer::Base.delivery_method

ActiveRecord::Base.transaction do
  ActionMailer::Base.delivery_method = :test

  # --- 1. inštalácia ---------------------------------------------------------
  puts "\n[1] Instalacia"
  plugin = Redmine::Plugin.find(:redmine_inapp_notifications) rescue nil
  puts "  plugin je nacitany          : #{ok(!plugin.nil?)} (#{plugin&.version})"
  puts "  tabulka existuje            : #{ok(ActiveRecord::Base.connection.table_exists?('inapp_notifications'))}"
  puts "  Mailer patch aplikovany     : #{ok(Mailer.ancestors.include?(InappNotifications::MailerPatch))}"
  puts "  Member patch aplikovany     : #{ok(Member.included_modules.include?(InappNotifications::MemberPatch))}"
  # Partial index je to jediné, čo drží odznak rýchly na každom renderi každej stránky.
  idx = ActiveRecord::Base.connection.indexes('inapp_notifications').map(&:name)
  puts "  partial index na neprecitane: #{ok(idx.include?('index_inapp_notifications_unread'))}"
  puts "  unique index proti duplicite: #{ok(idx.include?('index_inapp_notifications_dedup'))}"

  # --- 2. záchyt z mailu -----------------------------------------------------
  puts "\n[2] Zachyt notifikacie z realneho mailu"
  issue = Issue.where.not(:assigned_to_id => nil).order(:id => :desc).first
  recipients = issue.notified_users
  before = InappNotification.count
  ActionMailer::Base.deliveries.clear
  Mailer.with_synched_deliveries { Mailer.deliver_issue_add(issue) }
  created = InappNotification.count - before
  mails   = ActionMailer::Base.deliveries.size
  puts "  adresatov / mailov / riadkov: #{recipients.size} / #{mails} / #{created}"
  # Kľúčové tvrdenie celého pluginu: in-app kopíruje mail 1:1.
  puts "  riadkov = poslanych mailov  : #{ok(created == mails)}"
  puts "  source je spravny           : #{ok(InappNotification.where(:source_type => 'Issue', :source_id => issue.id).exists?)}"
  puts "  project_id je vyplneny      : #{ok(InappNotification.where(:source_id => issue.id).first&.project_id == issue.project_id)}"

  # --- 3. no_self_notified ---------------------------------------------------
  # Autor nedostane mail o vlastnej zmene, takže nesmie dostať ani notifikáciu.
  # Toto je test, že sa rozhodujeme z `message.to` a nie z argumentu akcie.
  puts "\n[3] Autor vlastnej zmeny"
  author = issue.author
  puts "  autor nema riadok           : #{ok(!InappNotification.where(:user_id => author.id, :source_id => issue.id, :source_type => 'Issue').exists?)}" \
       "#{author.pref.no_self_notified ? '' : ' (pozn.: autor ma no_self_notified vypnute)'}"

  # --- 4. whitelist ----------------------------------------------------------
  puts "\n[4] Whitelist akcii"
  someone = User.active.where.not(:id => author.id).first
  b = InappNotification.count
  Mailer.with_synched_deliveries { Mailer.deliver_test_email(someone) }
  puts "  test_email nevytvori riadok : #{ok(InappNotification.count == b)}"
  b = InappNotification.count
  token = Token.new(:user => someone, :action => 'recovery')
  token.save
  Mailer.with_synched_deliveries { Mailer.deliver_lost_password(someone, token) }
  puts "  lost_password nevytvori nic : #{ok(InappNotification.count == b)}"
  puts "  neznama akcia sa preskoci   : #{ok(!InappNotifications::Events.known?('something_new'))}"

  # --- 5. idempotencia -------------------------------------------------------
  puts "\n[5] Duplicity"
  b = InappNotification.count
  Mailer.with_synched_deliveries { Mailer.deliver_issue_add(issue) }
  puts "  opakovane dorucenie         : #{ok(InappNotification.count == b)} (pribudlo #{InappNotification.count - b})"

  # --- 6. naše pluginy zadarmo ----------------------------------------------
  # Toto je hlavný argument pre napojenie na Mailer: cudzie mailery fungujú bez zásahu.
  puts "\n[6] Nase pluginy bez jedineho zasahu"
  puts "  reaction_added je v mape    : #{ok(InappNotifications::Events.known?('reaction_added'))}"
  puts "  remind_me_due je v mape     : #{ok(InappNotifications::Events.known?('remind_me_due'))}"
  # POZOR na signaturu: `Mailer.deliver_reaction_added(reaction, user)` — prijemcu si
  # vybera volajuci (`NotifyReactions.deliver`), nie mailer. Instancna akcia ma opacne
  # poradie, `reaction_added(user, reaction)`, aby sedela s `Mailer#process`.
  if Mailer.respond_to?(:deliver_reaction_added) && Setting.reactions_enabled?
    target  = Journal.where.not(:notes => '').where.not(:user_id => nil).order(:id => :desc).first
    reactor = User.active.where.not(:id => target.user_id).first
    reaction = Reaction.new(:reactable => target, :user => reactor)
    if reaction.save
      b = InappNotification.count
      Mailer.with_synched_deliveries { Mailer.deliver_reaction_added(reaction, target.user) }
      created = InappNotification.count - b
      puts "  lajk vytvori notifikaciu    : #{ok(created.positive?)} (pribudlo #{created})"
      puts "  a ma spravny source         : #{ok(InappNotification.where(:source_type => 'Reaction', :source_id => reaction.id).exists?)}"
    else
      puts "  lajk                        : (preskocene — reakciu sa nepodarilo vytvorit)"
    end
  else
    puts "  lajk                        : (preskocene — plugin alebo reakcie vypnute)"
  end

  # --- 7. viditeľnosť --------------------------------------------------------
  # Najdôležitejší bezpečnostný test. `Journal#visible?` NEROZLISUJE sukromne poznamky —
  # rozlisuje ich len scope `Journal.visible(user)`. Zamena by bola diera.
  puts "\n[7] Viditelnost"
  outsider = User.active.detect { |u| !u.admin? && !issue.visible?(u) }
  if outsider
    InappNotification.create!(:user_id => outsider.id, :event => 'issue_add',
                              :source_type => 'Issue', :source_id => issue.id,
                              :created_on => Time.current)
    rows = InappNotifications::Loader.new(outsider).list(:limit => 50)
    puts "  cudzia uloha sa nevykresli  : #{ok(rows.none? { |r| r.source.id == issue.id })}"
    puts "  riadok ale ZOSTAVA v DB     : #{ok(InappNotification.where(:user_id => outsider.id, :source_id => issue.id).exists?)} (pravo sa moze vratit)"
  else
    puts "  cudzia uloha                : (preskocene — nenasiel sa vhodny user)"
  end

  priv = Journal.where(:private_notes => true).where.not(:notes => '').order(:id => :desc).first
  if priv
    blind = User.active.detect do |u|
      !u.admin? && priv.issue&.visible?(u) && !u.allowed_to?(:view_private_notes, priv.issue.project)
    end
    if blind
      InappNotification.create!(:user_id => blind.id, :event => 'issue_edit',
                                :source_type => 'Journal', :source_id => priv.id,
                                :created_on => Time.current)
      rows = InappNotifications::Loader.new(blind).list(:limit => 50)
      puts "  sukromna poznamka skryta    : #{ok(rows.none? { |r| r.source.id == priv.id })}"
    else
      puts "  sukromna poznamka           : (preskocene — nenasiel sa vhodny user)"
    end
  else
    puts "  sukromna poznamka           : (preskocene — ziadna v datach)"
  end

  # --- 8. mŕtve riadky -------------------------------------------------------
  puts "\n[8] Mrtve a nezname zdroje"
  victim = User.active.where(:admin => false).first
  InappNotification.create!(:user_id => victim.id, :event => 'issue_add',
                            :source_type => 'Issue', :source_id => 99_999_999,
                            :created_on => Time.current)
  InappNotification.create!(:user_id => victim.id, :event => 'issue_add',
                            :source_type => 'Zombie', :source_id => 1,
                            :created_on => Time.current)
  rows = InappNotifications::Loader.new(victim).list(:limit => 50)
  puts "  neexistujuci zdroj sa zmazal: #{ok(!InappNotification.where(:user_id => victim.id, :source_id => 99_999_999).exists?)}"
  puts "  neznamy typ nezhodi loader  : #{ok(rows.is_a?(Array))}"
  puts "  neznamy typ sa zmazal       : #{ok(!InappNotification.where(:user_id => victim.id, :source_type => 'Zombie').exists?)}"

  # --- 9. čítanie a odznak ---------------------------------------------------
  puts "\n[9] Precitane a odznak"
  reader = InappNotification.where.not(:user_id => nil).first&.user
  if reader
    n_before = InappNotification.unread_count_for(reader)
    InappNotification.for_user(reader).unread.update_all(:read_on => Time.current)
    puts "  read_all vynuluje odznak    : #{ok(InappNotification.unread_count_for(reader).zero?)} (pred: #{n_before})"
  end

  # --- 10. retencia ----------------------------------------------------------
  puts "\n[10] Retencia"
  old = InappNotification.create!(:user_id => victim.id, :event => 'issue_add',
                                  :source_type => 'Issue', :source_id => issue.id,
                                  :created_on => 400.days.ago, :read_on => 399.days.ago)
  fresh = InappNotification.create!(:user_id => victim.id, :event => 'issue_edit',
                                    :source_type => 'Issue', :source_id => issue.id,
                                    :created_on => Time.current)
  InappNotifications.purge!
  puts "  stary zaznam zmazany        : #{ok(!InappNotification.exists?(old.id))}"
  puts "  novy zaznam zostal          : #{ok(InappNotification.exists?(fresh.id))}"

  # --- 11. N+1 (najdôležitejší test) ----------------------------------------
  # Počet dotazov NESMIE rásť s dĺžkou zoznamu. Dve miesta, ktoré to porušovali a sú
  # ošetrené v Presenteri: `Journal#event_title` aj `event_type` volajú `new_status`,
  # teda `IssueStatus.find_by_id` na KAŽDÝ riadok (namerané: +28 dotazov pri 40 riadkoch).
  puts "\n[11] N+1 — pocet dotazov nesmie rast s dlzkou zoznamu"
  bulk_user = User.active.where(:admin => false).first
  InappNotification.for_user(bulk_user).delete_all
  src_i = Issue.visible(bulk_user).order(:id => :desc).limit(60).to_a
  src_j = Journal.visible(bulk_user).where.not(:notes => '').order(:id => :desc).limit(60).to_a
  now = Time.current
  bulk = src_i.map { |i| { :user_id => bulk_user.id, :event => 'issue_add', :source_type => 'Issue',
                           :source_id => i.id, :project_id => i.project_id, :created_on => now, :read_on => nil } } +
         src_j.map { |j| { :user_id => bulk_user.id, :event => 'issue_edit', :source_type => 'Journal',
                           :source_id => j.id, :project_id => j.journalized.try(:project_id),
                           :created_on => now, :read_on => nil } }
  InappNotification.insert_all(bulk) if bulk.any?

  loader = InappNotifications::Loader.new(bulk_user)
  measured = {}
  [5, 20, 50].each do |lim|
    measured[lim] = count_sql do
      list = loader.list(:limit => lim)
      st   = loader.statuses_for(list)
      ActiveRecord::Base.cache do
        list.each { |r| InappNotifications::Presenter.new(r, :statuses => st).to_h }
      end
    end
  end
  puts "  dotazov pri 5/20/50 riadkoch: #{measured[5]} / #{measured[20]} / #{measured[50]}"
  puts "  20 riadkov pod 25 dotazov   : #{ok(measured[20] <= 25)}"
  # Kľúčové tvrdenie: z 20 na 50 riadkov (2,5x viac) nesmie počet dotazov výrazne narásť.
  puts "  50 riadkov nie je 2x viac   : #{ok(measured[50] <= measured[20] * 2)}"

  # --- 12. kill-switch -------------------------------------------------------
  puts "\n[12] Kill-switch"
  saved = Setting.plugin_redmine_inapp_notifications
  Setting.plugin_redmine_inapp_notifications = (saved || {}).to_h.merge('enabled' => '0')
  b = InappNotification.count
  Mailer.with_synched_deliveries { Mailer.deliver_issue_add(Issue.order(:id => :desc).second) }
  puts "  vypnuty plugin nezapisuje   : #{ok(InappNotification.count == b)}"
  Setting.plugin_redmine_inapp_notifications = saved

  raise ActiveRecord::Rollback
end

ActionMailer::Base.delivery_method = orig_delivery

puts "\n  (vsetko vratene rollbackom — riadkov v tabulke: #{InappNotification.count})"
puts "\n" + '=' * 78
