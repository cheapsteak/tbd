-- The loopback port this TBD home's model proxy binds.
--
-- Not a flag: NULL means "not yet minted" rather than "chose off", and there is
-- no value the shipped code could default it to. The first proxy is spawned
-- with port zero, reports what the kernel assigned, and the daemon persists it
-- here; every later proxy is asked to bind the same port. Minting is the
-- conditional UPDATE in ConfigStore.ensureModelProxyPort(minting:), the shape
-- ensureHolderOwnerToken already uses, so two daemons on one TBD home cannot
-- both mint. No DEFAULT clause, for the same reason as the flags above.
ALTER TABLE config ADD COLUMN model_proxy_port INTEGER;
