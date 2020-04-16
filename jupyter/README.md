# Jupyter Notebook Setup
---
Made this so next time I delete my home accidently I don't have to rediscover how to do this all over again
Environment python 3.7 Fedora 31

### Setup
Python virtual install setup

```
virtualenv ~/py37
source ~/py37/bin/activate
pip install jupyter
pip install jupyterthemes
pip install jupyterlab
```

This is a buggy part of where installing within a virtualenv failst with permission denies if you don't create the following directories.
```
sudo mkdir /usr/local/share/jupyter
sudo chmod 777 /usr/local/share/jupyter
sudo mkdir /usr/local/etc/jupyter
sudo chmod 777 /usr/local/etc/jupyter
```

### Extensions
Here we install the desired nbExtensions and enable them

```
pip install jupyter_contrib_nbextensions && jupyter contrib nbextension install
jupyter contrib nbextension install
```

You will need to enable the extensions (start an instance):
- ExecuteTime
- jupyter-js-widgets/extension
- Nbextensions dashboard tab
- Autopep8
- contrib_nbextensions_help_item
- Hide input
- Nbextensions edit menu item
- spellchecker


### Appearence
Next we like dark themes and such, so we need to setup our own custom CSS.
Copy the `custom.css` file to `${HOME}/.jupyter/custom/custom.css` and then restart jupyter-notebook instance.

