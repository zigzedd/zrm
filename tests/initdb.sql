-- Cleanup existing database content.
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;

-- Create models table.
CREATE TABLE models (
	id SERIAL PRIMARY KEY,
	name VARCHAR NOT NULL,
	amount NUMERIC(12, 2) NOT NULL
);

-- Create submodels table.
CREATE TABLE submodels (
	uuid UUID PRIMARY KEY,
	label VARCHAR NOT NULL,
	parent_id INT NULL,
	FOREIGN KEY (parent_id) REFERENCES models ON DELETE RESTRICT ON UPDATE CASCADE
);
CREATE INDEX submodels_parent_id_index ON submodels(parent_id);

-- Insert default data.
INSERT INTO models(name, amount) VALUES ('test', 50);
INSERT INTO models(name, amount) VALUES ('updatable', 33.12);
INSERT INTO submodels(uuid, label, parent_id) VALUES ('f6868a5b-2efc-455f-b76e-872df514404f', 'test', 1);
INSERT INTO submodels(uuid, label, parent_id) VALUES ('013ef171-9781-40e9-b843-f6bc11890070', 'another', 1);

-- Create composite models table.
CREATE TABLE composite_models (
	firstcol SERIAL NOT NULL,
	secondcol VARCHAR NOT NULL,
	label VARCHAR NULL,
	PRIMARY KEY (firstcol, secondcol)
);
