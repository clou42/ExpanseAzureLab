-- Create crew_manifest table
CREATE TABLE crew_manifest (
    id INT PRIMARY KEY IDENTITY(1,1),
    first_name NVARCHAR(50),
    last_name NVARCHAR(50),
    faction NVARCHAR(50),
    role NVARCHAR(50),
    ship NVARCHAR(50),
    status NVARCHAR(50)
);

-- Insert data into crew_manifest
INSERT INTO crew_manifest (first_name, last_name, faction, role, ship, status) VALUES
('James', 'Holden', 'OPA', 'Captain', 'Rocinante', 'Active'),
('Naomi', 'Nagata', 'OPA', 'Engineer', 'Rocinante', 'Active'),
('Amos', 'Burton', 'OPA', 'Mechanic', 'Rocinante', 'Active'),
('Alex', 'Kamal', 'OPA', 'Pilot', 'Rocinante', 'Deceased'),
('Chrisjen', 'Avasarala', 'UN', 'Secretary-General', NULL, 'Active'),
('Josephus', 'Miller', 'Star Helix', 'Detective', NULL, 'Presumed Dead'),
('Bobbie', 'Draper', 'MCRN', 'Marine', NULL, 'Active');

-- Create protomolecule_incidents table
CREATE TABLE protomolecule_incidents (
    incident_id INT PRIMARY KEY IDENTITY(1,1),
    location NVARCHAR(100),
    description NVARCHAR(255),
    reported_by NVARCHAR(100),
    containment_status NVARCHAR(50),
    timestamp DATETIME DEFAULT GETDATE()
);

-- Insert data into protomolecule_incidents
INSERT INTO protomolecule_incidents (location, description, reported_by, containment_status) VALUES
('Eros Station', 'Mass infection event linked to Protomolecule experiment', 'Josephus Miller', 'Failed'),
('Venus Orbit', 'Unknown structure forming in atmosphere', 'James Holden', 'Unresolved'),
('Ganymede', 'Blue goo sighted post-battle', 'Bobbie Draper', 'Contained');

CREATE TABLE dbo.espionage_credentials
(
    id                INT              IDENTITY(1,1) PRIMARY KEY,
    faction           NVARCHAR(32)     NOT NULL
        CHECK (faction IN (N'UN', N'MCRN', N'OPA')),

    subject_name      NVARCHAR(120)    NOT NULL,
    subject_title     NVARCHAR(120)    NULL,
    clearance_level   NVARCHAR(32)     NULL,

    principal_type    NVARCHAR(32)     NOT NULL
        CHECK (principal_type IN (N'User', N'ServicePrincipal')),

    upn               NVARCHAR(255)    NULL,
    app_display_name  NVARCHAR(255)    NULL,
    app_id            UNIQUEIDENTIFIER NULL,
    object_id         UNIQUEIDENTIFIER NULL,
    tenant_id         UNIQUEIDENTIFIER NULL,

    credential_type   NVARCHAR(32)     NULL
        CHECK (credential_type IN (N'Password', N'Certificate', N'Key', N'Other')),
    secret_hint       NVARCHAR(255)    NULL,
    secret NVARCHAR(255)   NULL, -- marker instead of real secrets
    cert_thumbprint   NVARCHAR(64)     NULL,
    key_vault_uri     NVARCHAR(512)    NULL,

    valid_from        DATETIME2(3)     NULL,
    valid_to          DATETIME2(3)     NULL,

    compromised       BIT              NOT NULL DEFAULT(0),
    compromised_at    DATETIME2(3)     NULL,
    source            NVARCHAR(255)    NULL,
    notes             NVARCHAR(4000)   NULL,

    created_at        DATETIME2(3)     NOT NULL DEFAULT (SYSUTCDATETIME())
);

INSERT INTO dbo.espionage_credentials
(faction, subject_name, subject_title, clearance_level, principal_type,
 upn, app_display_name, app_id, tenant_id,
 credential_type, secret_hint, secret, cert_thumbprint, key_vault_uri,
 valid_from, valid_to, compromised, source, notes)
VALUES
-- UN officials (fake users)
(N'UN',  N'Elara Vance',  N'Communications Analyst', N'Confidential', N'User',
 N'elara.vance@un.fake', NULL, NULL, NULL,
 N'Password', N'Birth year of Eros incident', N'***PLACEHOLDER***', NULL, NULL,
 SYSUTCDATETIME(), DATEADD(month,12,SYSUTCDATETIME()), 0,
 N'Freds Wishlist', N'We really want their credentials.'),

(N'UN',  N'Marco Bellin', N'Strategy Advisor', N'Secret', N'User',
 N'marco.bellin@un.fake', NULL, NULL, NULL,
 N'Password', N'Surname of favorite admiral', N'***PLACEHOLDER***', NULL, NULL,
 SYSUTCDATETIME(), DATEADD(month,6,SYSUTCDATETIME()), 0,
 N'Freds Wishlist', N'We really want their credentials.'),

-- MCRN staff (fake users)
(N'MCRN', N'Tara Singh',  N'Fleet Engineer', N'Secret', N'User',
 N'tara.singh@mcrn.fake', NULL, NULL, NULL,
 N'Password', N'Her first ship class', N'***PLACEHOLDER***', NULL, NULL,
 SYSUTCDATETIME(), DATEADD(month,18,SYSUTCDATETIME()), 0,
 N'Freds Wishlist', N'We really want their credentials.'),

(N'MCRN', N'Yuri Nakamura', N'Logistics Officer', N'Confidential', N'User',
 N'yuri.nakamura@mcrn.fake', NULL, NULL, NULL,
 N'Password', N'Childhood pet name', N'***PLACEHOLDER***', NULL, NULL,
 SYSUTCDATETIME(), DATEADD(month,8,SYSUTCDATETIME()), 0,
 N'Freds Wishlist', N'We really want their credentials.'),

-- OPA infiltrators (fake users)
(N'OPA', N'Serena Koa',  N'Infiltration Specialist', N'None', N'User',
 N'serena.koa@opa.fake', NULL, NULL, NULL,
 N'Password', N'Rocinante hull number', N'***PLACEHOLDER***', NULL, NULL,
 SYSUTCDATETIME(), DATEADD(month,24,SYSUTCDATETIME()), 0,
 N'Freds Wishlist', N'We really want their credentials.'),

(N'OPA', N'Barto Leone', N'Data Broker', N'None', N'User',
 N'barto.leone@opa.fake', NULL, NULL, NULL,
 N'Password', N'Belter proverb + random digits', N'***PLACEHOLDER***', NULL, NULL,
 SYSUTCDATETIME(), DATEADD(month,24,SYSUTCDATETIME()), 0,
 N'Freds Wishlist', N'We really want their credentials.'),

(N'UN', N'Chrisjen Avasarala', N'Secretary-General', N'Top Secret', N'ServicePrincipal',
 NULL, N'Chrisjen', '11111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111',
 N'Key',
 N'Allows for managing the UN Fleet Cluster', N'NOT PROVISIONED YET', NULL, N'I wish I knew this.',
 SYSUTCDATETIME(), DATEADD(year,3,SYSUTCDATETIME()), 0,
 N'Policy intercept at Tycho', N'The secretary generals keys to the fleet.'),

-- Fake Service Principals (UN and MCRN)
(N'UN', N'UN-DeepSpaceTelemetry', N'Ingestion App', N'Top Secret', N'ServicePrincipal',
 NULL, N'un-deepspace-telemetry-sp', '11111111-1111-1111-1111-111111111111', 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
 N'Password', N'KV entry: fake-secret-1', N'***PLACEHOLDER***', NULL, N'https://fakevault-un.vault.azure.net/',
 SYSUTCDATETIME(), DATEADD(year,1,SYSUTCDATETIME()), 0,
 N'Freds Wishlist', N'We really want their credentials.'),

(N'MCRN', N'MCRN-MunitionsOps', N'Automation SP', N'Secret', N'ServicePrincipal',
 NULL, N'mcrn-munitions-sp', '22222222-2222-2222-2222-222222222222', 'BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF',
 N'Certificate', N'Bogus thumbprint XYZ123', N'***PLACEHOLDER***', N'XYZ123FAKECERT', N'https://fakevault-mcrn.vault.azure.net/',
 SYSUTCDATETIME(), DATEADD(year,2,SYSUTCDATETIME()), 0,
 N'Freds Wishlist', N'We really want their credentials.'),

-- More filler records for realism
(N'UN', N'Jonas Richter', N'Policy Clerk', N'Confidential', N'User',
 N'jonas.richter@un.fake', NULL, NULL, NULL,
 N'Password', N'Obvious wrong hint', N'***PLACEHOLDER***', NULL, NULL,
 SYSUTCDATETIME(), DATEADD(month,6,SYSUTCDATETIME()), 0,
 N'Freds Wishlist', N'We really want their credentials.'),

(N'MCRN', N'Aleya Fong', N'Navigation Specialist', N'Secret', N'User',
 N'aleya.fong@mcrn.fake', NULL, NULL, NULL,
 N'Password', N'Planet name backwards', N'***PLACEHOLDER***', NULL, NULL,
 SYSUTCDATETIME(), DATEADD(month,6,SYSUTCDATETIME()), 0,
 N'Freds Wishlist', N'We really want their credentials.');

-- Type-specific identity checks
ALTER TABLE dbo.espionage_credentials WITH CHECK ADD CONSTRAINT CK_ec_identity
CHECK (
    (principal_type = N'User' AND upn IS NOT NULL)
 OR (principal_type = N'ServicePrincipal' AND app_id IS NOT NULL)
);


CREATE TABLE dbo.ships (
    id         INT IDENTITY(1,1) PRIMARY KEY,
    name       NVARCHAR(100)  NOT NULL,
    registry   NVARCHAR(50)   NOT NULL,
    faction    NVARCHAR(50)   NOT NULL,
    tonnage    INT            NOT NULL CONSTRAINT DF_ships_tonnage DEFAULT (0),
    class      NVARCHAR(50)   NULL,
    status     NVARCHAR(50)   NULL,
    created_at DATETIME2(3)   NOT NULL CONSTRAINT DF_ships_created_at DEFAULT (SYSUTCDATETIME())
);

-- Seed some ships so the vulnerable search has data to leak
INSERT INTO dbo.ships (name, registry, faction, tonnage, class, status) VALUES
(N'Rocinante',   N'OPA-ROC', N'OPA',  2400,   N'Frigate',       N'Active'),
(N'Donnager',    N'MCR-DON', N'MCRN', 120000, N'Battleship',    N'Destroyed'),
(N'Scirocco',    N'MCR-SCI', N'MCRN', 65000,  N'Heavy Cruiser', N'Active'),
(N'Behemoth',    N'OPA-BEH', N'OPA',  450000, N'Battleship',    N'Active'),
(N'Agatha King', N'UNN-AGA', N'UNN',  75000,  N'Destroyer',     N'Destroyed');

-- Indexes aligned with your vulnerable LIKE query on name/registry
CREATE INDEX IX_ships_name     ON dbo.ships(name);
CREATE INDEX IX_ships_registry ON dbo.ships(registry);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_crew_manifest_ship' AND object_id = OBJECT_ID('dbo.crew_manifest'))
  CREATE INDEX IX_crew_manifest_ship ON dbo.crew_manifest(ship);