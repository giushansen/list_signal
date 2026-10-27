defmodule LS.Repo.Migrations.ResetLegacyExportCounters do
  use Ecto.Migration

  @moduledoc """
  The CSV counter never reset before 2026-10-27 (nothing read
  `exports_reset_at`), so `exports_used_this_month` held the account's
  lifetime exports, not a month's. The rows-metering migration stamped
  those rows with today, which made a lifetime number count against the
  new, smaller monthly pool: the owner's account showed 25,000 of 15,000
  rows spent on the day it shipped. Nobody has a true "this month" count
  from before today, so every counter starts at zero now.
  """

  def up do
    execute "UPDATE users SET exports_used_this_month = 0"
  end

  def down, do: :ok
end
