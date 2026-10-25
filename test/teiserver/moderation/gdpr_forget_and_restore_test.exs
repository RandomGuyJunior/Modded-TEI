defmodule Teiserver.Moderation.GDPRForgetAndRestoreTest do
  alias Teiserver.AccountFixtures
  alias Teiserver.Helpers.GeneralTestLib
  alias Teiserver.Logging.LoggingTestLib
  alias Teiserver.Moderation
  alias Teiserver.Moderation.AntiAbuseRecord
  alias Teiserver.Moderation.CreateAntiAbuseRecordTask
  alias Teiserver.Moderation.RefreshUserRestrictionsTask
  alias Teiserver.Moderation.RestoreForgottenUserTask

  use Teiserver.DataCase, async: false

  test "GDPR forget and restore" do
    # Create a user, forget them, restore them
    user = AccountFixtures.user_fixture()
    admin = AccountFixtures.user_fixture()
    scope = GeneralTestLib.scope_fixture(admin)

    # Need to define this as a value since we can't later use it inside
    # a match
    user_id = user.id

    {:ok, _action} =
      Moderation.create_action(%{
        target_id: user.id,
        reason: "reason",
        restrictions: ["Login"],
        expires: DateTime.utc_now() |> DateTime.shift(year: 1),
        score_modifier: 0
      })

    RefreshUserRestrictionsTask.refresh_user(user.id)

    {:ok, %AntiAbuseRecord{} = record} =
      CreateAntiAbuseRecordTask.create_anti_abuse_record_from_user_id(
        user.id,
        scope,
        "no notes"
      )

    # We will test the contents shortly but for now we want to be sure
    # we have not created keys in the wrong places
    assert match?(
             %{
               user_id: ^user_id,
               clean: false,
               notes: "no notes",
               restored_by_id: nil,
               restored_at: nil,
               hashes: %{
                 email: "" <> _email,
                 discord_id: nil,
                 steam_id: nil,
                 decrypt_keys: %{
                   email: "" <> _email_key,
                   discord_id: nil,
                   steam_id: nil
                 },
                 restore_data: "" <> _encrypted_data
               }
             },
             record
           )

    # Assert we have created the audit log too
    audit_log = LoggingTestLib.get_most_recent_audit_log_for_user(admin.id)

    assert match?(
             %{
               action: "Anti-abuse record access",
               details: %{"action" => "create"}
             },
             audit_log
           )

    # Stage 2: Forget the user
    # TODO

    # Next up, we need to ensure we can find the record
    assert is_nil(RestoreForgottenUserTask.find_record_from_identifier(:discord_id, user.email))
    assert is_nil(RestoreForgottenUserTask.find_record_from_identifier(:steam_id, user.email))

    found_record = RestoreForgottenUserTask.find_record_from_identifier(:email, user.email)

    # The items are not identical because the record hashes uses atoms for keys as it
    # is from the changeset, both having the same ID is acceptable as a check because we use UUIDs
    # for AARs and as such won't accidentally end up with an identical ID
    assert found_record.id == record.id

    # Assert that this has not come back in an unencrypted format
    assert match?(
             {:error, %Jason.DecodeError{}},
             Jason.decode(found_record.hashes["restore_data"])
           )

    # Now can we restore it?
    # TODO actually restore it, for now we just want to ensure the decode process works
    restore_data = RestoreForgottenUserTask.restore_from_record(found_record, :email, user.email)

    assert restore_data == %{
             "avoided_by" => [],
             "blocked_by" => [],
             "ignored_by" => [],
             "smurf_keys" => []
           }
  end
end
