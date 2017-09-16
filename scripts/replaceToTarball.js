#!/usr/bin/env node
const fs = require('fs')
const pkg = require('../package.json')

const root = process.cwd()
const string = `"${pkg.name}": "file:../`

function replaceConstant(path) {
  fs.readFile(path, 'utf8', (err, data) => {
    if (err) {
      return err
    }

    const result = data.replace(string, `${string}${process.env.tarball_name}`)
    return fs.writeFile(path, result, 'utf8', error => (
      error && console.error(error) // eslint-disable-line
    ))
  })
}


replaceConstant(`${root}/example/package.json`)
