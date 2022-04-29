# README

[![Build Status](https://github.com/openHPI/dockercontainerpool/workflows/CI/badge.svg)](https://github.com/openHPI/dockercontainerpool/actions?query=workflow%3ACI)

This project is designed to work in conjunction with [CodeOcean](https://github.com/openHPI/codeocean) **on the same local machine**.

## Deprecation Warning

We no longer recommend using DockerContainerPool as an executor for CodeOcean. Instead, we suggest using [Poseidon](https://github.com/openHPI/poseidon) for the best performance and security. Therefore, this project is no longer maintained actively.

## Local Setup

The setup is similar to CodeOcean and (unfortunately), this ReadMe is still work in progress. Assuming you have CodeOcean installed, perform these steps for the DockerContainerPool in the project root:

```shell script
bundle install
```

Check `database.yml` for the correct database name (use the same as for CodeOcean!) and validate `docker.yml.erb` (both are in the `config` directory). You don't need to initialize a dedicated database for this project.

In order to allow seamless filesharing for Docker contaiers, you should set the following symlink, depending on the environment you wish to run the server. Replace `$SOURCE_ROOT` with a valid path to the CodeOcean repository and this repositroy.

```
ln -s $SOURCE_ROOT/CodeOcean/tmp/files/development $SOURCE_ROOT/DockerContainerPool/tmp/files
```

Once you're done, start the server:

```
rails s
```
