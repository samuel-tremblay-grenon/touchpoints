class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :lockable
  devise :database_authenticatable,
         :rememberable,
         :trackable,
         :timeoutable

  devise :omniauthable, omniauth_providers: Rails.configuration.x.omniauth.providers

  belongs_to :organization, optional: true
  has_many :user_roles, dependent: :destroy
  has_many :forms, through: :user_roles, primary_key: "form_id"


  after_create :send_new_user_notification

  APPROVED_DOMAINS = [".gov", ".mil"]

  validates :email, presence: true, if: :tld_check

  def self.admins
    User.where(admin: true)
  end

  def self.from_omniauth(auth)
    # Set login_dot_gov as Provider for legacy TP Devise accounts
    # TODO: Remove once all accounts are migrated/have `provider` and `uid` set
    @existing_user = User.find_by_email(auth.info.email)
    if @existing_user && !@existing_user.provider.present?
      @existing_user.provider = auth.provider
      @existing_user.uid = auth.uid
      @existing_user.save
    end

    # For login.gov native accounts
    where(provider: auth.provider, uid: auth.uid).first_or_create do |user|
      user.email = auth.info.email
      user.password = Devise.friendly_token[0,24]
    end
  end

  def tld_check
    unless ENV['GITHUB_CLIENT_ID'].present? or APPROVED_DOMAINS.any? { |word| email.end_with?(word) }
      errors.add(:email, "is not from a valid TLD - #{APPROVED_DOMAINS.to_sentence} domains only")
      return false
    end

    # Call this from here, because I want to hard return if email fails.
    # Specifying `ensure_organization` as validator
    #  ran every time (even when email was not valid), which was undesirable
    ensure_organization
  end

  def organization_name
    if organization.present?
      organization.name
    elsif admin?
      "Admin"
    end
  end

  def role
    if self.admin?
      "Admin"
    elsif self.organization_manager?
      "Organization Manager"
    else
      "User"
    end
  end

  # For Devise
  # This determines whether a user is inactive or not
  def active_for_authentication?
    self && !self.inactive?
  end

  # For Devise
  # This is the flash message shown to a user when inactive
  def inactive_message
    "User account is inactive"
  end

  def deactivate
    self.inactive = true
    self.save
    UserMailer.org_manager_change_notification(self,'removed').deliver_later if self.organization_manager?
    UserMailer.account_deactivated_notification(self).deliver_later
    Event.log_event(Event.names[:user_deactivated], "User", self.id, "User account #{self.email} deactivated on #{Date.today}")
  end

  private

    def parse_host_from_domain(string)
      fragments = string.split(".")
      if fragments.size == 2
        return string
      elsif fragments.size == 3
        fragments.shift
        return fragments.join(".")
      elsif fragments.size == 4
        fragments.shift
        fragments.shift
        return fragments.join(".")
      end
    end

    def ensure_organization
      email_address_domain = Mail::Address.new(self.email).domain
      parsed_domain = parse_host_from_domain(email_address_domain)

      if org = Organization.find_by_domain(parsed_domain)
        self.organization_id = org.id
      else
        UserMailer.no_org_notification(self).deliver_later if self.id
        errors.add(:organization, "'#{email_address_domain}' has not yet been configured for Touchpoints - Please contact the Feedback Analytics Team for assistance.")
      end
    end

    def send_new_user_notification
      # Send notification to Touchpoints
      UserMailer.new_user_notification(self).deliver_later

      # Send notification to Org Admins
      self.organization.users.select { |user| user.organization_manager? }.each do |om|
        UserMailer.org_user_notification(self, om).deliver_later
      end
    end
end
