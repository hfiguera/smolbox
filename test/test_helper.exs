# Including ordinary runtime qualification must not opt into native owner/helper
# loss or persistence-interruption campaigns. Keep their selection independent.
ExUnit.start(exclude: [:runtime, :deferred_crash])
