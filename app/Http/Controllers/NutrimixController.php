<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;

class NutrimixController extends Controller
{
    public function index()
    {
        return view('nutrimix.index');
    }
}