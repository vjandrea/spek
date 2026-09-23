#pragma once

#include <wx/wx.h>

class SpekHaveSampleEvent: public wxEvent
{
public:
    SpekHaveSampleEvent(int bands, int sample, float *values, bool free_values);
    SpekHaveSampleEvent(const SpekHaveSampleEvent& other);
    ~SpekHaveSampleEvent();

    int get_bands() const { return this->bands; }
    int get_sample() const { return this->sample; }
    const float *get_values() const { return this->values; }

    wxEvent *Clone() const { return new SpekHaveSampleEvent(*this); }

private:
    int bands;
    int sample;
    float *values;
    bool free_values;
};

typedef void (wxEvtHandler::*SpekHaveSampleEventFunction)(SpekHaveSampleEvent&);

// Not DECLARE_EVENT_TYPE: that macro applies wx's own WXDLLIMPEXP_CORE
// dllimport/dllexport decoration, appropriate for wx's own event types but
// not for one we define ourselves, and mismatches the plain (undecorated)
// definition in spek-events.cc when wx itself is a DLL (e.g. MSYS2's mingw
// wx package), causing a Windows link error.
extern const wxEventType SPEK_HAVE_SAMPLE;

#define SPEK_EVT_HAVE_SAMPLE(fn) \
    DECLARE_EVENT_TABLE_ENTRY(SPEK_HAVE_SAMPLE, -1, -1, \
    (wxObjectEventFunction) (SpekHaveSampleEventFunction) &fn, (wxObject *) NULL ),
