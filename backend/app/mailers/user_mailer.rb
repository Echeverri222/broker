# NTF-01: transactional mail only. One template per type, all plain text. Never includes balances or passwords.
class UserMailer < ApplicationMailer
  self.deliver_later_queue_name = :default

  def verify_email(user)
    @user = user
    @url = app_url("/verify-email?token=#{CGI.escape(user.generate_token_for(:email_verification))}")
    mail(to: user.email, subject: "Confirm your email for Paper Broker")
  end

  def password_reset(user)
    @user = user
    @url = app_url("/reset-password?token=#{CGI.escape(user.generate_token_for(:password_reset))}")
    mail(to: user.email, subject: "Reset your Paper Broker password")
  end

  def password_changed(user)
    @user = user
    mail(to: user.email, subject: "Your Paper Broker password was changed")
  end

  def order_filled(order)
    @order = order
    @user = order.account.user
    mail(to: @user.email, subject: "Your #{order.side} order for #{order.asset.symbol} was filled")
  end

  def order_rejected(order)
    @order = order
    @user = order.account.user
    mail(to: @user.email, subject: "Your #{order.side} order for #{order.asset.symbol} could not be filled")
  end
end
