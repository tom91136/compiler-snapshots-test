import ScalaJSConfig from './scalajs.webpack.config.js';

import {merge} from 'webpack-merge';

var local = {
    devtool: false,
    devServer: {
        compress: true,
        https:true,
        headers: {
            "Access-Control-Allow-Origin": "*"
        },
    },
    performance: {
        // See https://github.com/scalacenter/scalajs-bundler/pull/408
        // and also https://github.com/scalacenter/scalajs-bundler/issues/350
        hints: false
    },
    module: {
        rules: [
            {
                test: /\.css$/,
                use: ['style-loader', 'css-loader'],
                type: 'javascript/auto',
            },
            {
                test: /\.(eot|ttf|woff(2)?|svg|png|glb|jpeg|jpg|mp4|jsn)$/,
                type: 'asset/resource',
                generator: {
                    filename: 'static/[hash][ext][query]'
                }
                // use: 'file-loader',
            }

        ]
    }
};

export default merge(ScalaJSConfig, local)
