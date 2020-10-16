# README

This project is designed to work in conjunction with [CodeOcean](https://github.com/openHPI/codeocean) **on the same local machine**.

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
