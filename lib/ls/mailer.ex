defmodule LS.Mailer do
  @moduledoc "Swoosh mailer — transactional email (magic links, billing notices)."
  use Swoosh.Mailer, otp_app: :ls
end
