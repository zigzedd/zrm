-- Cleanup existing database content.
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;

-- Create default models table.
CREATE TABLE models (
	id SERIAL PRIMARY KEY,
	name VARCHAR NOT NULL,
	amount NUMERIC(12, 2) NOT NULL
);

-- Insert default data.
INSERT INTO models(name, amount) VALUES ('test', 50);
INSERT INTO models(name, amount) VALUES ('updatable', 33.12);

-- Create default composite models table.
CREATE TABLE composite_models (
	firstcol SERIAL NOT NULL,
	secondcol VARCHAR NOT NULL,
	label VARCHAR NULL,
	PRIMARY KEY (firstcol, secondcol)
);
