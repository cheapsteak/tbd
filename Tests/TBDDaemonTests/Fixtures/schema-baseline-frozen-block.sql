CREATE TABLE "claude_cloud_session" ("id" TEXT PRIMARY KEY NOT NULL, "idempotencyKey" TEXT NOT NULL, "state" TEXT NOT NULL, "sessionID" TEXT, "title" TEXT, "createdAt" DATETIME NOT NULL, "resolvedAt" DATETIME, "repoKey" TEXT NOT NULL, "repoPath" TEXT NOT NULL, "branch" TEXT, "environment" TEXT, "paramsJSON" TEXT NOT NULL, "archived" BOOLEAN NOT NULL DEFAULT 0);
CREATE TABLE "config" ("id" TEXT PRIMARY KEY NOT NULL, "default_profile_id" TEXT REFERENCES "model_profiles"("id") ON DELETE SET NULL, "claude_env_settings" TEXT, "primary_agent_preference" TEXT, "env_overrides" TEXT, "auto_archive_on_merge_default" BOOLEAN DEFAULT 0, "scratch_instructions" TEXT, "scratch_rename_prompt" TEXT, "scratch_profile_override_id" TEXT, "nightwatch_mode" TEXT DEFAULT 'off', "auto_hibernate_enabled" BOOLEAN DEFAULT 1, "hibernate_idle_minutes" INTEGER DEFAULT 30, "auto_resume_on_limit_reset" BOOLEAN DEFAULT 0, "control_mode_enabled" BOOLEAN DEFAULT 0, "auto_resume_on_api_error" BOOLEAN DEFAULT 0, "auto_hibernate_on_merge_default" BOOLEAN DEFAULT 0, "hibernate_input_veto_enabled" BOOLEAN DEFAULT 0, "gc_enabled" BOOLEAN DEFAULT 1, "gc_grace_seconds" INTEGER DEFAULT 3600, "gc_snapshot_retention_days" INTEGER DEFAULT 30, "auto_close_setup_enabled" BOOLEAN DEFAULT 0, "daemon_panel_surface_enabled" BOOLEAN DEFAULT 0, "agent_panel_control_enabled" BOOLEAN DEFAULT 0, "remote_backends_enabled" BOOLEAN DEFAULT 0, "auto_trust_worktrees" BOOLEAN DEFAULT 1, "delivery_verification_enabled" BOOLEAN DEFAULT 0, "queued_prompt_enabled" BOOLEAN, "supervision_enabled" BOOLEAN, "gc_profile_dirs_enabled" BOOLEAN, "claude_cloud_enabled" BOOLEAN, "gc_orphan_processes_enabled" BOOLEAN);
CREATE TABLE "forgotten_worktree" ("path" TEXT PRIMARY KEY NOT NULL, "repoID" TEXT NOT NULL, "forgottenAt" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP);
CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
CREATE TABLE "model_profile_usage" ("profile_id" TEXT PRIMARY KEY NOT NULL REFERENCES "model_profiles"("id") ON DELETE CASCADE, "five_hour_pct" DOUBLE, "seven_day_pct" DOUBLE, "five_hour_resets_at" DATETIME, "seven_day_resets_at" DATETIME, "fetched_at" DATETIME, "last_status" TEXT);
CREATE TABLE "model_profiles" ("id" TEXT PRIMARY KEY NOT NULL, "name" TEXT NOT NULL UNIQUE, "keychain_ref" TEXT NOT NULL, "kind" TEXT NOT NULL, "created_at" DATETIME NOT NULL, "last_used_at" DATETIME, "base_url" TEXT, "model" TEXT, "aws_region" TEXT, "aws_profile" TEXT, "fallback_models" TEXT, "env_overrides" TEXT, "sort_order" INTEGER DEFAULT 0);
CREATE TABLE "note" ("id" TEXT PRIMARY KEY NOT NULL, "worktreeID" TEXT NOT NULL REFERENCES "worktree"("id") ON DELETE CASCADE, "title" TEXT NOT NULL, "content" TEXT NOT NULL DEFAULT '', "createdAt" DATETIME NOT NULL, "updatedAt" DATETIME NOT NULL);
CREATE TABLE "notification" ("id" TEXT PRIMARY KEY NOT NULL, "worktreeID" TEXT NOT NULL REFERENCES "worktree"("id") ON DELETE CASCADE, "type" TEXT NOT NULL, "message" TEXT, "read" BOOLEAN NOT NULL DEFAULT 0, "createdAt" DATETIME NOT NULL, "terminalID" TEXT);
CREATE TABLE "oauth_profile_usage_snapshot" ("profile_id" TEXT PRIMARY KEY NOT NULL REFERENCES "model_profiles"("id") ON DELETE CASCADE, "snapshot_json" TEXT NOT NULL);
CREATE TABLE "panel_history" ("panelID" TEXT PRIMARY KEY NOT NULL, "tabID" TEXT NOT NULL REFERENCES "workspace_tab_surface"("id") ON DELETE CASCADE, "history" TEXT NOT NULL, "updatedAt" DATETIME NOT NULL);
CREATE TABLE "panel_operation_receipt" ("operationID" TEXT PRIMARY KEY NOT NULL, "worktreeID" TEXT NOT NULL REFERENCES "worktree"("id") ON DELETE CASCADE, "tabID" TEXT NOT NULL, "revision" INTEGER NOT NULL, "result" TEXT NOT NULL, "appliedAt" DATETIME NOT NULL);
CREATE TABLE "reap_records" ("id" TEXT PRIMARY KEY, "kind" TEXT NOT NULL, "repoPath" TEXT NOT NULL, "worktreePath" TEXT NOT NULL, "branch" TEXT, "headSHA" TEXT, "snapshotRef" TEXT, "apparentBytes" INTEGER, "reapedAt" DATETIME NOT NULL, "restoredAt" DATETIME, "quarantinePath" TEXT, "processDescription" TEXT);
CREATE TABLE "remote_session" ("provider" TEXT NOT NULL, "sessionID" TEXT NOT NULL, "payload" TEXT NOT NULL, "state" TEXT NOT NULL, "agentState" TEXT, "firstSeen" DATETIME NOT NULL, "lastSeen" DATETIME NOT NULL, "missingCount" INTEGER NOT NULL DEFAULT 0, "gone" BOOLEAN NOT NULL DEFAULT 0, "dismissed" BOOLEAN NOT NULL DEFAULT 0, "resolvedRepoID" TEXT, "pinnedAt" DATETIME, PRIMARY KEY ("provider", "sessionID"));
CREATE TABLE "repo" ("id" TEXT PRIMARY KEY NOT NULL, "path" TEXT NOT NULL UNIQUE, "remoteURL" TEXT, "displayName" TEXT NOT NULL, "defaultBranch" TEXT NOT NULL, "createdAt" DATETIME NOT NULL, "renamePrompt" TEXT, "customInstructions" TEXT, "profile_override_id" TEXT, "worktree_slot" TEXT, "worktree_root" TEXT, "status" TEXT NOT NULL DEFAULT 'ok', "hidden" BOOLEAN NOT NULL DEFAULT 0, "expanded" BOOLEAN NOT NULL DEFAULT 1, "env_overrides" TEXT, "claude_settings_overlay" TEXT);
CREATE TABLE "scheduled_resumes" ("id" TEXT PRIMARY KEY, "terminalID" TEXT NOT NULL, "worktreeID" TEXT NOT NULL, "claudeSessionID" TEXT, "resetsAt" DATETIME NOT NULL, "fireAt" DATETIME NOT NULL, "limitType" TEXT NOT NULL, "rawMessage" TEXT NOT NULL, "createdAt" DATETIME NOT NULL, "status" TEXT NOT NULL, "attemptCount" INTEGER NOT NULL DEFAULT 0);
CREATE TABLE "tab" ("id" TEXT PRIMARY KEY, "worktreeID" TEXT NOT NULL, "label" TEXT, "createdAt" DATETIME NOT NULL);
CREATE TABLE "tbd_meta" ("key" TEXT PRIMARY KEY NOT NULL, "value" TEXT NOT NULL);
CREATE TABLE "terminal" ("id" TEXT PRIMARY KEY NOT NULL, "worktreeID" TEXT NOT NULL REFERENCES "worktree"("id") ON DELETE CASCADE, "tmuxWindowID" TEXT NOT NULL, "tmuxPaneID" TEXT NOT NULL, "label" TEXT, "createdAt" DATETIME NOT NULL, "pinnedAt" DATETIME, "claudeSessionID" TEXT, "suspendedAt" DATETIME, "suspendedSnapshot" TEXT, "profile_id" TEXT, "transcriptPath" TEXT, "kind" TEXT, "activityState" TEXT DEFAULT 'unknown', "hibernatedAt" DATETIME, "keepWarm" BOOLEAN DEFAULT 0, "pendingResumeAt" DATETIME, "hibernateReason" TEXT, "watch_desk_role" TEXT DEFAULT NULL, "activityStateSource" TEXT, "activityStateObservedAt" DATETIME, "awaitingInputReason" TEXT, "awaitingInputObservedAt" DATETIME, "activityStateOrderObservedAt" DATETIME DEFAULT NULL, "sessionOrderObservedAt" DATETIME DEFAULT NULL);
CREATE TABLE "terminal_history" ("id" TEXT PRIMARY KEY NOT NULL, "worktreeID" TEXT NOT NULL, "label" TEXT, "kind" TEXT, "closedAt" DATETIME NOT NULL, "claudeSessionID" TEXT, "lineCount" INTEGER NOT NULL DEFAULT 0);
CREATE TABLE "watch_desk_judge_lease" ("worktree_id" TEXT PRIMARY KEY NOT NULL REFERENCES "worktree"("id") ON DELETE CASCADE, "terminal_id" TEXT NOT NULL, "token" TEXT NOT NULL, "generation" INTEGER NOT NULL, "acquired_at" DATETIME NOT NULL, "renewed_at" DATETIME NOT NULL, "expires_at" DATETIME NOT NULL);
CREATE TABLE "workspace_tab_surface" ("id" TEXT PRIMARY KEY NOT NULL, "worktreeID" TEXT NOT NULL REFERENCES "worktree"("id") ON DELETE CASCADE, "primaryContent" TEXT NOT NULL, "label" TEXT, "position" INTEGER NOT NULL, "layout" TEXT NOT NULL, "revision" INTEGER NOT NULL DEFAULT 0, "updatedAt" DATETIME NOT NULL);
CREATE TABLE "worktree" (
    id TEXT PRIMARY KEY NOT NULL,
    repoID TEXT REFERENCES repo(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    displayName TEXT NOT NULL,
    branch TEXT NOT NULL,
    path TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL DEFAULT 'active',
    createdAt DATETIME NOT NULL,
    archivedAt DATETIME,
    tmuxServer TEXT NOT NULL,
    gitStatus TEXT NOT NULL DEFAULT 'current',
    hasConflicts BOOLEAN NOT NULL DEFAULT 0,
    pinnedAt DATETIME,
    archivedClaudeSessions TEXT,
    sortOrder INTEGER NOT NULL DEFAULT 0,
    archivedHeadSHA TEXT,
    tabOrder TEXT NOT NULL DEFAULT '[]',
    activeTabID TEXT,
    parentWorktreeID TEXT REFERENCES worktree(id) ON DELETE SET NULL,
    autoArchiveOnMerge BOOLEAN,
    prStatus TEXT,
    promotedToRepoID TEXT
, "autoHibernateOnMerge" BOOLEAN, "pr_number" INTEGER, "panel_surface_imported_at" DATETIME, "pinSortOrder" INTEGER, "foreign_head" BOOLEAN DEFAULT 0, "location" TEXT DEFAULT 'local', "providerName" TEXT, "providerSessionID" TEXT, "pending_prompt" TEXT, "pending_prompt_submit" BOOLEAN DEFAULT 1, "prObservation" TEXT);
CREATE TABLE "worktree_pull_request" ("id" TEXT PRIMARY KEY NOT NULL, "worktreeID" TEXT NOT NULL REFERENCES "worktree"("id") ON DELETE CASCADE, "host" TEXT NOT NULL DEFAULT 'github.com', "owner" TEXT NOT NULL, "repo" TEXT NOT NULL, "number" INTEGER NOT NULL, "url" TEXT NOT NULL, "headBranch" TEXT, "baseRef" TEXT, "prStatus" TEXT, "source" TEXT NOT NULL, "detached" BOOLEAN NOT NULL DEFAULT 0, "boundAt" DATETIME NOT NULL, "title" TEXT);
CREATE UNIQUE INDEX idx_claude_cloud_session_key ON claude_cloud_session(idempotencyKey);
CREATE INDEX idx_claude_cloud_session_session ON claude_cloud_session(sessionID) WHERE sessionID IS NOT NULL;
CREATE INDEX idx_forgotten_worktree_repoID ON forgotten_worktree(repoID);
CREATE INDEX idx_panel_history_tab ON panel_history(tabID);
CREATE INDEX idx_panel_receipt_worktree ON panel_operation_receipt(worktreeID, appliedAt);
CREATE INDEX idx_reap_records_repo ON reap_records(repoPath);
CREATE UNIQUE INDEX idx_repo_worktree_slot
    ON repo(worktree_slot)
    WHERE worktree_slot IS NOT NULL;
CREATE UNIQUE INDEX idx_scheduled_resumes_one_pending ON scheduled_resumes(terminalID) WHERE status = 'pending';
CREATE INDEX idx_terminal_history_worktree ON terminal_history(worktreeID);
CREATE INDEX idx_workspace_tab_surface_worktree ON workspace_tab_surface(worktreeID, position);
CREATE INDEX idx_worktree_provider_session ON worktree(providerName, providerSessionID) WHERE providerName IS NOT NULL;
CREATE UNIQUE INDEX idx_worktree_pull_request_identity ON worktree_pull_request(worktreeID, host, owner, repo, number);
CREATE INDEX idx_worktree_pull_request_worktree ON worktree_pull_request(worktreeID);
