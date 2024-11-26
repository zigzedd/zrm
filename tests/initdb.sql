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



-- Create example models.

CREATE TABLE example_medias (
	id SERIAL PRIMARY KEY,
	filename VARCHAR NOT NULL
);

CREATE TABLE example_users (
	id SERIAL PRIMARY KEY,
	name VARCHAR NOT NULL,
	picture_id INT
);

CREATE TABLE example_users_info (
	user_id INT PRIMARY KEY,
	birthdate TIMESTAMP WITH TIME ZONE NOT NULL
);

CREATE TABLE example_messages (
	id SERIAL PRIMARY KEY,
	text TEXT NOT NULL,
	user_id INT NOT NULL
);

CREATE TABLE example_messages_medias (
	message_id INT NOT NULL,
	media_id INT NOT NULL,
	PRIMARY KEY (message_id, media_id)
);

-- Fill example models.

INSERT INTO example_medias (filename) VALUES ('profile.jpg'), ('profile.png'), ('attachment.png'), ('video.mp4'), ('music.opus');

INSERT INTO example_users (name, picture_id) VALUES
  ('test', 1),
	('madeorsk', 1),
	('foo', 2),
	('bar', NULL),
	('baz', NULL);

INSERT INTO example_users_info (user_id, birthdate) VALUES
	(2, '1997-10-09');

INSERT INTO example_messages (text, user_id) VALUES
	('this is a test', 2),
	('I want to test something.', 1),
	('Lorem ipsum dolor sit amet', 1),
	('Je pense donc je suis', 4),
	('The quick brown fox jumps over the lazy dog', 3),
	('foo bar baz', 1),
	('How are you?', 2),
	('Fine!', 3);

INSERT INTO example_messages_medias (message_id, media_id) VALUES
	(1, 3),
	(2, 4),
	(6, 3),
	(6, 5),
	(8, 2);
