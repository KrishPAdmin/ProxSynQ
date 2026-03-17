--
-- PostgreSQL database dump
--

\restrict 7XTbwUTJisnUVeQ3ZQ2CxzIK2OxEYA9gc10eb54i5B7NzzIApNO4V9DI4eZi5Th

-- Dumped from database version 16.11 (Debian 16.11-1.pgdg13+1)
-- Dumped by pg_dump version 16.11 (Debian 16.11-1.pgdg13+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: arbiter_actions; Type: TABLE; Schema: public; Owner: proxsyncq
--

CREATE TABLE public.arbiter_actions (
    id integer NOT NULL,
    action text NOT NULL,
    target text NOT NULL,
    reason text,
    proxmox_task text,
    triggered_at timestamp with time zone DEFAULT now() NOT NULL,
    outcome text
);


ALTER TABLE public.arbiter_actions OWNER TO proxsyncq;

--
-- Name: arbiter_actions_id_seq; Type: SEQUENCE; Schema: public; Owner: proxsyncq
--

CREATE SEQUENCE public.arbiter_actions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.arbiter_actions_id_seq OWNER TO proxsyncq;

--
-- Name: arbiter_actions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: proxsyncq
--

ALTER SEQUENCE public.arbiter_actions_id_seq OWNED BY public.arbiter_actions.id;


--
-- Name: conflicts; Type: TABLE; Schema: public; Owner: proxsyncq
--

CREATE TABLE public.conflicts (
    id integer NOT NULL,
    file_path text NOT NULL,
    node_a text NOT NULL,
    node_b text NOT NULL,
    hash_a text NOT NULL,
    hash_b text NOT NULL,
    clock_a bigint DEFAULT 0 NOT NULL,
    clock_b bigint DEFAULT 0 NOT NULL,
    saved_path_a text,
    saved_path_b text,
    detected_at timestamp with time zone DEFAULT now() NOT NULL,
    resolved boolean DEFAULT false NOT NULL,
    resolved_at timestamp with time zone,
    resolved_by text,
    notes text
);


ALTER TABLE public.conflicts OWNER TO proxsyncq;

--
-- Name: conflicts_id_seq; Type: SEQUENCE; Schema: public; Owner: proxsyncq
--

CREATE SEQUENCE public.conflicts_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.conflicts_id_seq OWNER TO proxsyncq;

--
-- Name: conflicts_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: proxsyncq
--

ALTER SEQUENCE public.conflicts_id_seq OWNED BY public.conflicts.id;


--
-- Name: file_versions; Type: TABLE; Schema: public; Owner: proxsyncq
--

CREATE TABLE public.file_versions (
    id integer NOT NULL,
    node_name text NOT NULL,
    file_path text NOT NULL,
    content_hash text NOT NULL,
    logical_clock bigint DEFAULT 0 NOT NULL,
    size_bytes bigint DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    synced_at timestamp with time zone
);


ALTER TABLE public.file_versions OWNER TO proxsyncq;

--
-- Name: file_versions_id_seq; Type: SEQUENCE; Schema: public; Owner: proxsyncq
--

CREATE SEQUENCE public.file_versions_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.file_versions_id_seq OWNER TO proxsyncq;

--
-- Name: file_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: proxsyncq
--

ALTER SEQUENCE public.file_versions_id_seq OWNED BY public.file_versions.id;


--
-- Name: job_results; Type: TABLE; Schema: public; Owner: proxsyncq
--

CREATE TABLE public.job_results (
    job_id uuid NOT NULL,
    finished_at timestamp with time zone DEFAULT now() NOT NULL,
    result jsonb DEFAULT '{}'::jsonb NOT NULL
);


ALTER TABLE public.job_results OWNER TO proxsyncq;

--
-- Name: jobs; Type: TABLE; Schema: public; Owner: proxsyncq
--

CREATE TABLE public.jobs (
    job_id uuid NOT NULL,
    job_type text NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    idempotency_key text,
    priority integer DEFAULT 0 NOT NULL,
    submitted_at timestamp with time zone DEFAULT now() NOT NULL,
    submitted_by text NOT NULL,
    state text DEFAULT 'queued'::text NOT NULL,
    claimed_by text,
    claimed_at timestamp with time zone,
    lease_expires_at timestamp with time zone,
    attempt_count integer DEFAULT 0 NOT NULL,
    last_error text
);


ALTER TABLE public.jobs OWNER TO proxsyncq;

--
-- Name: sync_events; Type: TABLE; Schema: public; Owner: proxsyncq
--

CREATE TABLE public.sync_events (
    id integer NOT NULL,
    node_name text NOT NULL,
    event_type text NOT NULL,
    file_path text NOT NULL,
    from_node text,
    detail text,
    occurred_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.sync_events OWNER TO proxsyncq;

--
-- Name: sync_events_id_seq; Type: SEQUENCE; Schema: public; Owner: proxsyncq
--

CREATE SEQUENCE public.sync_events_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.sync_events_id_seq OWNER TO proxsyncq;

--
-- Name: sync_events_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: proxsyncq
--

ALTER SEQUENCE public.sync_events_id_seq OWNED BY public.sync_events.id;


--
-- Name: arbiter_actions id; Type: DEFAULT; Schema: public; Owner: proxsyncq
--

ALTER TABLE ONLY public.arbiter_actions ALTER COLUMN id SET DEFAULT nextval('public.arbiter_actions_id_seq'::regclass);


--
-- Name: conflicts id; Type: DEFAULT; Schema: public; Owner: proxsyncq
--

ALTER TABLE ONLY public.conflicts ALTER COLUMN id SET DEFAULT nextval('public.conflicts_id_seq'::regclass);


--
-- Name: file_versions id; Type: DEFAULT; Schema: public; Owner: proxsyncq
--

ALTER TABLE ONLY public.file_versions ALTER COLUMN id SET DEFAULT nextval('public.file_versions_id_seq'::regclass);


--
-- Name: sync_events id; Type: DEFAULT; Schema: public; Owner: proxsyncq
--

ALTER TABLE ONLY public.sync_events ALTER COLUMN id SET DEFAULT nextval('public.sync_events_id_seq'::regclass);


--
-- Name: arbiter_actions arbiter_actions_pkey; Type: CONSTRAINT; Schema: public; Owner: proxsyncq
--

ALTER TABLE ONLY public.arbiter_actions
    ADD CONSTRAINT arbiter_actions_pkey PRIMARY KEY (id);


--
-- Name: conflicts conflicts_pkey; Type: CONSTRAINT; Schema: public; Owner: proxsyncq
--

ALTER TABLE ONLY public.conflicts
    ADD CONSTRAINT conflicts_pkey PRIMARY KEY (id);


--
-- Name: file_versions file_versions_node_name_file_path_key; Type: CONSTRAINT; Schema: public; Owner: proxsyncq
--

ALTER TABLE ONLY public.file_versions
    ADD CONSTRAINT file_versions_node_name_file_path_key UNIQUE (node_name, file_path);


--
-- Name: file_versions file_versions_pkey; Type: CONSTRAINT; Schema: public; Owner: proxsyncq
--

ALTER TABLE ONLY public.file_versions
    ADD CONSTRAINT file_versions_pkey PRIMARY KEY (id);


--
-- Name: job_results job_results_pkey; Type: CONSTRAINT; Schema: public; Owner: proxsyncq
--

ALTER TABLE ONLY public.job_results
    ADD CONSTRAINT job_results_pkey PRIMARY KEY (job_id);


--
-- Name: jobs jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: proxsyncq
--

ALTER TABLE ONLY public.jobs
    ADD CONSTRAINT jobs_pkey PRIMARY KEY (job_id);


--
-- Name: sync_events sync_events_pkey; Type: CONSTRAINT; Schema: public; Owner: proxsyncq
--

ALTER TABLE ONLY public.sync_events
    ADD CONSTRAINT sync_events_pkey PRIMARY KEY (id);


--
-- Name: idx_jobs_idempotency_key; Type: INDEX; Schema: public; Owner: proxsyncq
--

CREATE UNIQUE INDEX idx_jobs_idempotency_key ON public.jobs USING btree (idempotency_key);


--
-- Name: job_results job_results_job_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: proxsyncq
--

ALTER TABLE ONLY public.job_results
    ADD CONSTRAINT job_results_job_id_fkey FOREIGN KEY (job_id) REFERENCES public.jobs(job_id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict 7XTbwUTJisnUVeQ3ZQ2CxzIK2OxEYA9gc10eb54i5B7NzzIApNO4V9DI4eZi5Th

