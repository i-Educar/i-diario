# frozen_string_literal: true

require 'base64'
require 'openssl'
require 'json'
require 'erb'

module Laguna
  # SSO Laguna: recebe token HMAC do i-Educar e autentica no i-Diário.
  # Após sign_in, responde HTML (não 302) para o browser gravar o cookie de
  # sessão antes de navegar — evita o sintoma "1ª vez login, 2ª vez entra".
  class SsoController < ApplicationController
    skip_before_action :authenticate_user!
    skip_before_action :check_entity_status
    skip_before_action :check_for_notifications
    skip_before_action :check_for_current_user_role
    skip_before_action :set_current_unity_id
    skip_before_action :set_current_user_role_id
    skip_before_action :check_user_has_name
    skip_before_action :check_password_expired
    skip_before_action :last_activity_at
    skip_before_action :check_user_first_access

    protect_from_forgery with: :null_session, prepend: true

    def show
      process_sso
    rescue StandardError => e
      Rails.logger.error("[Laguna SSO] #{e.class}: #{e.message}\n#{e.backtrace&.first(8)&.join("\n")}")
      redirect_to_login('Falha no SSO Laguna.')
    end

    private

    def current_entity
      return @current_entity if defined?(@current_entity) && @current_entity

      host = request_host_without_port
      @current_entity = Entity.find_by(domain: host)
      if @current_entity.nil? && local_entity_host_alias?(host)
        @current_entity = Entity.find_by(domain: 'localhost') ||
                          Entity.find_by(name: 'prefeitura') ||
                          Entity.first
      end
      @current_entity ||= Entity.find_by(name: 'prefeitura') || Entity.first
      Entity.current = @current_entity
      @current_entity
    end

    def request_host_without_port
      # nginx pode enviar Host com :8443; Entity.domain não inclui porta.
      request.host.to_s.split(':').first
    end

    def local_entity_host_alias?(host = request_host_without_port)
      %w[127.0.0.1 host.docker.internal ::1 localhost].include?(host.to_s)
    end

    def process_sso
      unless current_entity
        redirect_to_login('Entidade i-Diário não encontrada.')
        return
      end

      payload = verify_token(params[:token].to_s)
      if payload.blank?
        redirect_to_login('SSO inválido ou expirado. Use o mesmo login/senha do i-Educar.')
        return
      end

      user = find_or_create_user(payload)
      if user.blank? || !user.active_for_authentication?
        redirect_to_login('Usuário SSO não pôde ser ativado no i-Diário.')
        return
      end

      # Evita fluxo de "primeiro acesso" / troca forçada logo após SSO.
      # first_access? é método derivado (e-mail Portabilis + senha); não há coluna first_access.
      mark_sso_as_not_first_access!(user)

      ensure_admin_role(user) if ActiveModel::Type::Boolean.new.cast(payload['admin'])
      user.set_current_user_role! if user.current_user_role_id.blank? && user.user_roles.exists?

      sign_in(:user, user)
      # Força escrita da sessão antes da resposta HTML.
      session[:laguna_sso_at] = Time.now.to_i
      session[:laguna_sso_login] = user.login.to_s

      render_continue(after_sso_path)
    end

    def after_sso_path
      root_path
    rescue StandardError
      '/'
    end

    # Interstício same-origin: cookie Set-Cookie é gravado; só então navega.
    def render_continue(path)
      dest = ERB::Util.html_escape(path.to_s)
      dest_js = path.to_s.to_json
      html = <<~HTML
        <!DOCTYPE html>
        <html lang="pt-BR">
        <head>
          <meta charset="utf-8">
          <meta http-equiv="refresh" content="0;url=#{dest}">
          <title>Entrando no i-Diário…</title>
          <style>
            body{font-family:Manrope,Segoe UI,system-ui,sans-serif;background:#eef2f5;color:#142028;
                 display:grid;place-items:center;min-height:100vh;margin:0}
            .box{background:#fff;border:1px solid #d0dbe3;border-radius:12px;padding:22px 26px;
                 box-shadow:0 8px 24px rgba(14,42,58,.06);text-align:center;max-width:22rem}
            a{color:#1a5f78;font-weight:700;text-decoration:none}
            .spin{display:inline-block;width:18px;height:18px;border:2px solid #c9d4dc;
                  border-top-color:#0d7a6f;border-radius:50%;animation:s .7s linear infinite;margin-bottom:10px}
            @keyframes s{to{transform:rotate(360deg)}}
          </style>
        </head>
        <body>
          <div class="box">
            <div class="spin" aria-hidden="true"></div>
            <p>Entrando via i-Educar…</p>
            <p><a href="#{dest}">Continuar</a></p>
          </div>
          <script>window.location.replace(#{dest_js});</script>
        </body>
        </html>
      HTML
      render html: html.html_safe, layout: false, content_type: 'text/html'
    end

    def redirect_to_login(message)
      path = begin
        new_user_session_path
      rescue StandardError
        '/usuarios/logar'
      end
      redirect_to path, alert: message and return
    end

    def shared_secret
      path = Rails.root.join('.laguna-shared-token')
      return File.read(path).to_s.strip if File.readable?(path)

      ENV.fetch('IDIARIO_SSO_SECRET', '').to_s.strip
    end

    def verify_token(token)
      return nil if token.blank? || shared_secret.blank?

      body, sig = token.split('.', 2)
      return nil if body.blank? || sig.blank?

      expected = OpenSSL::HMAC.hexdigest('SHA256', shared_secret, body)
      return nil unless ActiveSupport::SecurityUtils.secure_compare(expected, sig)

      json = Base64.urlsafe_decode64(pad_base64(body))
      payload = JSON.parse(json)
      return nil if payload['exp'].to_i < Time.now.to_i

      payload
    rescue StandardError
      nil
    end

    def pad_base64(str)
      str + ('=' * ((4 - str.length % 4) % 4))
    end

    def find_or_create_user(payload)
      login = payload['login'].to_s
      email = payload['email'].to_s
      name = payload['name'].to_s
      password = login.presence || 'admin'
      admin_flag = ActiveModel::Type::Boolean.new.cast(payload['admin'])

      user = User.find_by(login: login) if login.present?
      user ||= User.find_by(email: email) if email.present?

      first, last = split_name(name)

      if user.nil?
        attrs = {
          login: login.presence || email.to_s.split('@').first,
          email: email.presence || "#{login}@sme.laguna.local",
          password: password,
          password_confirmation: password,
          status: 'active',
          kind: 'employee',
          admin: admin_flag,
          receive_news: false,
          first_name: first,
          last_name: last
        }
        # Só inclui atributos que existem nesta versão do User.
        attrs[:last_password_change] = Time.zone.today if User.column_names.include?('last_password_change')
        user = User.new(attrs)
        user.save(validate: false)
      else
        # Não reescreve senha a cada SSO (evita invalidar sessão/Devise salt).
        user.status = 'active' if user.respond_to?(:status=)
        user.admin = true if admin_flag
        user.first_name = first if user.first_name.blank?
        user.last_name = last if user.last_name.blank?
        mark_sso_as_not_first_access!(user)
        user.save(validate: false)
      end

      ensure_admin_role(user) if admin_flag
      user
    end

    def mark_sso_as_not_first_access!(user)
      return unless user.respond_to?(:first_access?) && user.first_access?
      return unless User.column_names.include?('last_password_change')

      user.last_password_change = Time.zone.today
      user.save(validate: false)
    rescue StandardError => e
      Rails.logger.warn("[Laguna SSO] mark_sso_as_not_first_access!: #{e.class}: #{e.message}")
    end

    def split_name(name)
      parts = name.to_s.split(/\s+/, 2)
      [parts[0].presence || 'Usuario', parts[1].to_s]
    end

    def ensure_admin_role(user)
      role = Role.order(:id).find_by(access_level: 'administrator')
      return if role.blank?

      UserRole.find_or_initialize_by(role: role, user: user).save(validate: false)
    end
  end
end
