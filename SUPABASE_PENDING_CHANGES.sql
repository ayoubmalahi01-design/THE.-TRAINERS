-- ============================================================================
-- THE TRAINERS – SUPABASE_PENDING_CHANGES.sql
-- Standalone pending SQL file (outside supabase/ at project root).
--
-- PURPOSE
--   Additive, data-preserving database changes required by the MASTER
--   EXECUTION PROMPT for the THE TRAINERS official-report feature set.
--
--   The live production database already contains the earlier report schema:
--     public.daily_reports (
--       ... report_date date,
--       ... shift_start timestamptz,
--       ... shift_end timestamptz,
--       ... finalized_at timestamptz,
--       ... reviewed_by uuid,
--       ... reviewed_at timestamptz,
--       ...
--     )
--
--   The application source (src/App.tsx, src/lib/report-export.ts) was extended
--   during this task to persist and export four independent report chronology
--   fields. The authoritative task requirements list these as independent
--   fields that must not be confused:
--     1. reporting_period_start  -> date   (start of the period covered)
--     2. reporting_period_end    -> date   (end of the period covered)
--     3. issue_date               -> date   (date the coach issued/prepared)
--     4. submitted_at             -> timestamptz (actual final submission time)
--
--   Migration 0004 has already been executed and must NOT be re-run.
--   No existing table, column, policy, trigger or function is modified here.
--   Only the genuinely missing additive columns above are added.
--
-- SAFETY
--   * Additive only: ADD COLUMN IF NOT EXISTS. No existing column is dropped,
--     renamed or rewritten.
--   * No table, data or row is deleted or modified.
--   * Nullable columns keep every existing report row valid immediately.
--   * The statements are tenant-aware by design because they only touch
--     public.daily_reports, whose institution scoping is already enforced by
--     existing RLS and triggers.
--   * No production execution is performed from this task; the file is prepared
--     here for explicit user approval only.

begin;

alter table public.daily_reports
  add column if not exists reporting_period_start date,
  add column if not exists reporting_period_end date,
  add column if not exists issue_date date,
  add column if not exists submitted_at timestamptz;

commit;

-- ============================================================================
-- SECTION 2 - TRUSTED OFFICIAL SUBMISSION TIMESTAMP (additive, pending approval)
-- ----------------------------------------------------------------------------
-- The official submission timestamp (public.daily_reports.submitted_at) must be
-- assigned by the trusted database workflow, never by the browser clock.
--
-- A BEFORE INSERT OR UPDATE trigger assigns submitted_at = now() only on the
-- transition of a report into the submitted/finalized state. Drafts keep
-- submitted_at = NULL. Already submitted reports are never re-assigned.
--
-- No existing table, column, policy, trigger or function is modified here;
-- only the new additive trigger function and trigger are created.
--
-- SAFETY
--   * Additive only: no existing object is dropped or rewritten (the trigger
--     name is new; drop trigger if exists guards the idempotent re-run).
--   * Drafts are never touched because they are not finalized.
--   * Historical valid submission timestamps are preserved; only NULL
--     submission timestamps of already-finalized reports are backfilled.

create or replace function public.set_daily_report_submitted_at() returns trigger
language plpgsql security definer set search_path=public,pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    if new.is_finalized = true and new.status = 'submitted' then
      new.submitted_at := now();
    end if;
  else
    if new.is_finalized = true and new.status = 'submitted' and not old.is_finalized then
      new.submitted_at := now();
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists daily_report_submitted_at on public.daily_reports;
create trigger daily_report_submitted_at
  before insert or update on public.daily_reports
  for each row
  when (new.is_finalized = true and new.status = 'submitted')
  execute function public.set_daily_report_submitted_at();

update public.daily_reports
set submitted_at = now()
where status = 'submitted' and is_finalized = true and submitted_at is null;

-- ============================================================================
-- SECTION 3 - REPORT DELETION POLICY (additive, pending approval)
-- ----------------------------------------------------------------------------
-- Institution administrators (manager/admin) may delete a completed/processed
-- report (status = 'reviewed'). The institution-scoped condition keeps every
-- deletion tenant-aware; cross-institution access remains impossible.
--
-- The director-only historical deletion rule is intentionally not encoded here
-- until the director role mapping is confirmed against the live database.

drop policy if exists reports_admin_delete on public.daily_reports;
create policy reports_admin_delete on public.daily_reports for delete to authenticated
using (
  institution_id = public.current_institution_id()
  and public.current_app_role() in ('manager','admin')
  and status = 'reviewed'
);

-- ============================================================================
-- SECTION 4 - ACADEMIC YEAR LIFECYCLE (additive, pending approval)
-- ----------------------------------------------------------------------------
-- Additive academic-year structures required by the academic-year lifecycle
-- repair. They support institution-scoped academic years with start/end dates,
-- current/archived states and a stable student -> academic-year enrollment model.
--
-- No existing table, column, policy, trigger or function is modified here;
-- only new additive objects are created. Historical rows are never rewritten.

create table if not exists public.academic_years (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  name text not null,
  start_date date,
  end_date date,
  is_current boolean not null default false,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists academic_years_institution_idx on public.academic_years(institution_id, is_current, is_archived);

create table if not exists public.student_academic_enrollments (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  academic_year_id uuid not null references public.academic_years(id) on delete cascade,
  institution_id uuid not null references public.institutions(id) on delete cascade,
  enrolled_on date,
  notes text,
  unique (student_id, academic_year_id)
);

create index if not exists student_academic_enrollments_year_idx on public.student_academic_enrollments(academic_year_id, institution_id);
create index if not exists student_academic_enrollments_student_idx on public.student_academic_enrollments(student_id, institution_id);

-- ============================================================================
-- SECTION 5 - INSTITUTION DELETION RPC (additive, pending approval)
-- ----------------------------------------------------------------------------
-- Director-only institution deletion workflow.
--
-- Authorization:
--   * Caller must be authenticated (auth.uid() is not null).
--   * Caller must hold the institution director role (public.current_app_role() = 'manager').
--   * Caller must belong to the target institution (public.current_institution_id() = p_institution_id).
--
-- Safety:
--   * The function is SECURITY DEFINER and runs with search_path = public, pg_temp.
--   * Permanent deletion only happens through this server-side function.
--   * Institution-owned child rows use ON DELETE CASCADE declared in the schema;
--     the institution row is the root of the institution-owned graph.
--   * Failures raise and never falsely report success.
--   * No production execution is performed here; the file is prepared for
--     explicit user approval only.

create or replace function public.delete_institution(p_institution_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if public.current_app_role() <> 'manager' then
    raise exception 'Only the institution director may delete an institution';
  end if;
  if public.current_institution_id() <> p_institution_id then
    raise exception 'Institution not found or not accessible';
  end if;
  delete from public.institutions where id = p_institution_id;
  return json_build_object('deleted', true, 'institution_id', p_institution_id);
end;
$$;

revoke execute on function public.delete_institution(uuid) from anon;
grant execute on function public.delete_institution(uuid) to authenticated;

-- ============================================================================
-- SECTION 6 - DIRECTOR HISTORICAL REPORT DELETION (additive, pending approval)
-- ----------------------------------------------------------------------------
-- Institution directors (manager role) may delete finalized/historical reports
-- within their own institution. This is additive to section 3 and does not
-- modify or remove existing policies. RLS permissive policies are OR-combined;
-- section 3 remains as previously prepared.
--
-- Note: Section 3 already permits manager/admin to delete reviewed reports.
-- This section extends director-only deletion to other finalized historical
-- reports as required by the workflow, while administration (admin role)
-- remains limited to reviewed/completed reports per UI and policy intent.

drop policy if exists reports_director_delete_historical on public.daily_reports;
create policy reports_director_delete_historical on public.daily_reports for delete to authenticated
using (
  institution_id = public.current_institution_id()
  and public.current_app_role() = 'manager'
  and is_finalized = true
);

-- ============================================================================
-- SECTION 7 - REPORT TEMPLATE STORAGE BUCKET (additive, pending approval)
-- ----------------------------------------------------------------------------
-- The application stores institution report templates in a private bucket
-- named "trainer-report-templates" (see src/App.tsx). The baseline setup SQL
-- does not create this bucket. This section is additive and idempotent.
--
-- IMPORTANT
--   * This only ensures the bucket exists. Storage RLS/policies for
--     storage.objects (institution-scoped admin/coach access as required by the
--     app) MUST be reviewed against the live database before/with approval;
--     this file does not add permissive storage policies because live policy
--     state is unverified in this environment.

insert into storage.buckets (id, name, public)
values ('trainer-report-templates', 'trainer-report-templates', false)
on conflict (id) do nothing;
