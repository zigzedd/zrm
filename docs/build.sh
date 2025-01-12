#!/bin/sh

yarn docs:build
(cd .vitepress/dist && tar cvzf docs.tar.gz * && mv docs.tar.gz ../..)
