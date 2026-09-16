# frozen_string_literal: true

class InappNotification < ActiveRecord::Base
  belongs_to :user

  scope :unread,   -> { where(:read_on => nil) }
  scope :for_user, ->(user) { where(:user_id => user.id) }
  # Stiahnuté = udalosť bola vzatá späť (odlajkované). Riadok sa NEMAŽE, aby sa pri
  # opätovnom lajku do okna dal použiť ten istý záznam namiesto novej notifikácie —
  # nikde sa však nepočíta ani nezobrazuje.
  scope :active,   -> { where(:retracted_on => nil) }
  # Radí sa podľa `id`, nie podľa `created_on`: id je monotónne a je v indexe
  # `[user_id, id]`, takže zoznam ide bez triedenia navyše. Pri dvoch notifikáciách
  # v tej istej sekunde navyše dáva stabilné poradie.
  scope :recent,   -> { order(:id => :desc) }

  def read?
    read_on.present?
  end

  # Počet pre odznak pri zvončeku. Beží na KAŽDOM renderi KAŽDEJ stránky, takže je to
  # holý COUNT nad partial indexom — žiadne načítanie objektov, žiadna kontrola viditeľnosti.
  #
  # Dôsledok: keď niekto stratí právo na projekt, môže byť číslo chvíľu vyššie než počet
  # riadkov, ktoré panel reálne ukáže. Rieši sa to dvoma spôsobmi a ani jeden nie je drahý:
  #   * odpoveď panelu nesie autoritatívny prefiltrovaný počet a JS ním odznak prepíše,
  #   * pri strate členstva sa notifikácie z toho projektu rovno mažú (MemberPatch).
  # Alternatíva — filtrovať viditeľnosť pri každom renderi každej stránky — je principiálne
  # správnejšia a prakticky neúnosná.
  def self.unread_count_for(user)
    return 0 unless user&.logged?

    for_user(user).unread.active.count
  end
end
